# frozen_string_literal: true

require "prism"

require_relative "analysis_guard"
require_relative "measurement_integrity"
require_relative "mutator"
require_relative "diagnostic_oracle"

module Rigor
  module Protection
    # ADR-63 Tier 2 — the mutation *effectiveness* tier (the truth tier behind Tier 1's static
    # {Inference::ProtectionScanner} proxy). For one file it answers the question Tier 1 only bounds: when a
    # type-visible bug is introduced at a dispatch site, does Rigor actually catch it?
    #
    # Mechanism (the ADR-62 warm loop, narrowed to per-file measurement): generate the type-visible mutations
    # ({Mutator}), keep only those whose receiver Rigor holds a concrete type for (the type-aware filter — the
    # FP-safe meaning-maker; an unresolved receiver is kept), then for each ask the **kill oracle** whether the
    # mutant is caught. The oracle is the ADR-69 seam: {#scan_file} uses the {DiagnosticOracle} (a *new Rigor
    # diagnostic* = a kill); {#scan_file_fused} additionally consults a {TestSuiteOracle} on the type-survivors
    # (ADR-70 — the dynamic protection axis).
    #
    # The expensive builds (RBS environment + the whole-project pre-pass scan) are paid ONCE by the caller and
    # threaded into the {DiagnosticOracle}; each mutant reuses them through `Runner.new(prebuilt:)#run_source`
    # (in-memory overlay, no disk write).
    class MutationScanner
      # A surviving mutation site — a breakage Rigor did not catch.
      SurvivingSite = Data.define(:line, :receiver, :method_name, :operator)

      # `harness_errors` (#264) — mutants where the harness itself failed (an exception `classify` rescued),
      # counted separately from a parse-invalid mutant. Defaults to 0 so every existing caller that builds a
      # `FileResult` without the new keyword — including the early-return-on-empty path below and the fork-scan
      # `ParseError` branch — keeps constructing one exactly as before.
      FileResult = Data.define(:path, :killed, :survived, :sites, :harness_errors) do
        def initialize(path:, killed:, survived:, sites:, harness_errors: 0)
          super
        end

        # Mutations actually analysed (parse-invalid mutants are not counted; neither are harness_errors — a
        # harness-level failure measures the harness, not the code, exactly like a parse-invalid mutant).
        def total = killed + survived

        # Issue #686 — "nothing was measured here" is NOT the same as "there was nothing to measure", and
        # `total.zero?` cannot tell them apart on its own. A file with no type-relevant mutation is
        # vacuously fully effective; a file whose every mutant landed in `harness_errors` measured the
        # harness and says nothing about the code. Before this, the second borrowed the first's 1.0 and a
        # wholly crashed file reported 100% effective.
        def measured? = MeasurementIntegrity.measured?(total: total, harness_errors: harness_errors)

        # Effectiveness ratio. 0.0 rather than 1.0 for an unmeasured file — both are wrong as a measurement,
        # and only one of them turns a red `--threshold` gate green. Read it next to {#measured?}, which is
        # what the renderer and the exit gate consult.
        def ratio
          return 0.0 unless measured?

          total.zero? ? 1.0 : killed.to_f / total
        end
      end

      # ADR-70 — one type-survivor classified by the dynamic (test) axis. `protection` is `:test` (a test caught
      # it) or `:none` (unprotected — the "add a type OR a test here" sites).
      FusedSite = Data.define(:line, :receiver, :method_name, :operator, :protection)

      # ADR-70 — the per-file fused classification. The gradual short-circuit collapses the conceptual
      # "doubly-protected" bucket into `type_killed`: a mutant the type checker already kills never reaches the
      # suite, because the static net already suffices and re-running the suite to learn a test *would also*
      # catch it is wasted work. So the observed buckets are three.
      # `harness_errors` (#264) — same bucket as {FileResult}, kept out of `total`/`ratio` exactly like a
      # parse-invalid mutant. Defaults to 0 for the same backward-compatibility reason.
      FusedFileResult = Data.define(:path, :type_killed, :test_killed, :sites, :harness_errors) do
        def initialize(path:, type_killed:, test_killed:, sites:, harness_errors: 0)
          super
        end

        # The unprotected sites (neither a type nor a test caught the breakage).
        def unprotected = sites.size
        def total = type_killed + test_killed + unprotected

        # Issue #686 — see {FileResult#measured?}.
        def measured? = MeasurementIntegrity.measured?(total: total, harness_errors: harness_errors)

        # Fused protected ratio — caught by *either* axis.
        def ratio
          return 0.0 unless measured?

          total.zero? ? 1.0 : (type_killed + test_killed).to_f / total
        end
      end

      # @param configuration [Rigor::Configuration]
      # @param environment [Rigor::Environment] pre-built once by the caller
      # @param project_scan [Rigor::Analysis::ProjectScan] pre-built once
      # @param limit [Integer, nil] optional per-file mutation cap (sampled with
      #   `seed`); nil analyses every type-relevant mutation (deterministic).
      # @param seed [Integer] RNG seed for the optional sample.
      # @param oracle [#baseline, #killed?, nil] the kill oracle (ADR-69 Seam 1);
      #   defaults to the {DiagnosticOracle} (the ADR-62/63 behaviour).
      # @param site_selector [:biteable, :all] which sites to mutate (ADR-69
      #   Seam 2). `:biteable` (default) keeps only concrete-type sites Rigor can
      #   bite; `:all` also mutates Dynamic-receiver dispatch sites — use only
      #   with a {TestSuiteOracle} (the fused overlay), never the diagnostic path.
      # @param base_scope [Rigor::Scope, nil] the scope site selection judges
      #   anchor types against, built once by the caller (see
      #   {Mutator#anchor_base_scope}). `nil` — the default — keeps the bare
      #   single-file empty scope. A caller that seeds cross-file discovery
      #   passes it here; this class stays free of {Rigor::Configuration} and of
      #   bleeding-edge feature ids, which live one layer up in the CLI.
      # @param discovery_seed [Hash, nil] issue #260 — the SAME cross-file table
      #   set `base_scope` was built from, threaded to the default
      #   {DiagnosticOracle} so an admitted cross-file site is one the oracle can
      #   also kill at. Pass both or neither: a `base_scope` without it measures
      #   sites no mutation can ever break. Ignored when `oracle` is supplied
      #   (that caller owns its oracle's knowledge).
      # rubocop:disable Metrics/ParameterLists -- every one is an independently-defaulted collaborator or knob;
      # bundling them into an options object would only move the list behind a name.
      def initialize(configuration:, environment:, project_scan:, limit: nil, seed: 1, oracle: nil,
                     site_selector: :biteable, base_scope: nil, discovery_seed: nil)
        # rubocop:enable Metrics/ParameterLists
        @environment = environment
        @limit = limit
        @seed = seed
        @site_selector = site_selector
        @base_scope = base_scope
        @oracle = oracle || DiagnosticOracle.new(
          configuration: configuration, environment: environment, project_scan: project_scan,
          discovery_seed: discovery_seed
        )
      end

      # @param path [String] the file to measure (used as the in-memory bind path)
      # @param source [String, nil] the file's source; read from disk when nil
      # @return [FileResult]
      def scan_file(path, source: nil)
        source ||= File.read(path, encoding: Encoding::UTF_8)
        kept = kept_mutations(source, path)
        return FileResult.new(path: path, killed: 0, survived: 0, sites: []) if kept.empty?

        baseline = clean_baseline(source, path)
        return crashed_baseline_result(path, kept.size) if baseline.nil?

        killed = 0
        harness_errors = 0
        sites = []
        kept.each do |mut|
          case classify(source, path, mut, baseline)
          when :killed then killed += 1
          when :survived then sites << surviving_site(mut)
          when :harness_error then harness_errors += 1
            # :invalid — a parse-broken mutant; not a measurement, skip it.
          end
        end
        FileResult.new(path: path, killed: killed, survived: sites.size, sites: sites, harness_errors: harness_errors)
      end

      # ADR-70 — the fused static∪dynamic measurement. Runs the type pass (the {DiagnosticOracle}); for every
      # mutant the type checker did **not** kill, asks `test_oracle` whether the project's test suite catches it.
      # The expensive suite run is paid only for type-survivors (the gradual short-circuit), so the cost is
      # proportional to the protection hole.
      # @param test_oracle [TestSuiteOracle]
      # @return [FusedFileResult]
      def scan_file_fused(path, test_oracle:, source: nil)
        source ||= File.read(path, encoding: Encoding::UTF_8)
        kept = kept_mutations(source, path)
        return FusedFileResult.new(path: path, type_killed: 0, test_killed: 0, sites: []) if kept.empty?

        baseline = clean_baseline(source, path)
        if baseline.nil?
          return FusedFileResult.new(path: path, type_killed: 0, test_killed: 0, sites: [],
                                     harness_errors: kept.size)
        end

        type_killed = 0
        test_killed = 0
        harness_errors = 0
        sites = []
        kept.each do |mut|
          case classify(source, path, mut, baseline)
          when :killed then type_killed += 1
          when :survived
            if test_oracle.killed?(path: path, original: source, mutant_source: mut.apply(source))
              test_killed += 1
            else
              sites << fused_site(mut, :none)
            end
          when :harness_error then harness_errors += 1
          end
        end
        FusedFileResult.new(path: path, type_killed: type_killed, test_killed: test_killed, sites: sites,
                            harness_errors: harness_errors)
      end

      private

      # The mutations to measure: the biteable filter (concrete-type sites only; the FP-safe default — an
      # unresolved receiver is kept) or, under the `:all` selector (ADR-69 Seam 2), every dispatch site including
      # Dynamic receivers. Optionally sampled.
      def kept_mutations(source, path)
        mutator = Mutator.new(source)
        muts = mutator.mutations
        kept =
          if @site_selector == :all
            mutator.dispatch_site_mutations(muts, environment: @environment, path: path, base_scope: @base_scope)
          else
            mutator.filter_by_type(muts, environment: @environment, path: path, base_scope: @base_scope).first
          end
        sample(kept)
      end

      # #264 — a parse-invalid mutant (`:invalid`, the mutation itself does not produce parseable Ruby) and a
      # harness-level failure (`:harness_error`, an exception raised *while measuring* an otherwise-parseable
      # mutant — e.g. the oracle's re-analysis blowing up) are different failure modes and MUST be told apart:
      # only the latter is a harness defect worth counting and surfacing. Both stay OUT of `killed + survived`
      # exactly as before (containment is unchanged) — #264 is about visibility, not about admitting either
      # bucket into the denominator.
      #
      # #686 — a {AnalysisGuard::AnalyzerCrashed} from the oracle's re-analysis arrives here as a
      # `StandardError` and lands in the same bucket, which is exactly right: an indeterminate mutant must
      # be scored neither killed nor survived. Before the oracle refused, a crashed re-analysis produced the
      # same synthetic diagnostic on both sides of the kill comparison, so the mutant was scored a SURVIVOR
      # and the harness reported a hole it had never measured.
      def classify(source, path, mut, baseline)
        mutant_source = mut.apply(source)
        return :invalid unless Prism.parse(mutant_source).success?

        @oracle.killed?(mutant_source: mutant_source, path: path, baseline: baseline) ? :killed : :survived
      rescue StandardError
        # A harness-level failure on one mutant must not abort the file — but it must not vanish either
        # (#264): the caller counts this bucket separately and the CLI surfaces it.
        :harness_error
      end

      # The clean per-file baseline, or nil when the analyzer crashed while computing it (#686).
      #
      # The baseline is computed ONCE per file, outside {#classify}'s per-mutant rescue, so a crash here is
      # not one mutant's problem: every mutant of this file would be judged against a baseline that knows
      # nothing, and each would come back a survivor. Reported as `harness_errors` — one per mutant that
      # would have been measured — rather than raised, so one bad file does not abort a whole sweep, and
      # rather than silently skipped, so the count the CLI already warns about accounts for it.
      #
      # Deliberately narrow: only {AnalyzerCrashed}. Any other exception out of an oracle's baseline
      # propagates exactly as it did before, because widening that rescue would hide unrelated harness bugs
      # behind the very bucket this issue exists to make honest.
      def clean_baseline(source, path)
        @oracle.baseline(source: source, path: path)
      rescue AnalyzerCrashed
        nil
      end

      def crashed_baseline_result(path, mutant_count)
        FileResult.new(path: path, killed: 0, survived: 0, sites: [], harness_errors: mutant_count)
      end

      def sample(mutations)
        return mutations unless @limit

        mutations.sample(@limit, random: Random.new(@seed))
      end

      def surviving_site(mut)
        SurvivingSite.new(line: mut.line, receiver: mut.anchor_type,
                          method_name: mut.method_name, operator: mut.operator.to_s)
      end

      def fused_site(mut, protection)
        FusedSite.new(line: mut.line, receiver: mut.anchor_type, method_name: mut.method_name,
                      operator: mut.operator.to_s, protection: protection)
      end
    end
  end
end
