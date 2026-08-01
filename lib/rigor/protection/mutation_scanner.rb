# frozen_string_literal: true

require "prism"

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

      FileResult = Data.define(:path, :killed, :survived, :sites) do
        # Mutations actually analysed (parse-invalid mutants are not counted).
        def total = killed + survived

        # Effectiveness ratio; a file with no type-relevant mutation is vacuously fully effective (no breakage
        # was available to miss).
        def ratio = total.zero? ? 1.0 : killed.to_f / total
      end

      # ADR-70 — one type-survivor classified by the dynamic (test) axis. `protection` is `:test` (a test caught
      # it) or `:none` (unprotected — the "add a type OR a test here" sites).
      FusedSite = Data.define(:line, :receiver, :method_name, :operator, :protection)

      # ADR-70 — the per-file fused classification. The gradual short-circuit collapses the conceptual
      # "doubly-protected" bucket into `type_killed`: a mutant the type checker already kills never reaches the
      # suite, because the static net already suffices and re-running the suite to learn a test *would also*
      # catch it is wasted work. So the observed buckets are three.
      FusedFileResult = Data.define(:path, :type_killed, :test_killed, :sites) do
        # The unprotected sites (neither a type nor a test caught the breakage).
        def unprotected = sites.size
        def total = type_killed + test_killed + unprotected

        # Fused protected ratio — caught by *either* axis.
        def ratio = total.zero? ? 1.0 : (type_killed + test_killed).to_f / total
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
      # rubocop:disable Metrics/ParameterLists -- every one is an independently-defaulted collaborator or knob;
      # bundling them into an options object would only move the list behind a name.
      def initialize(configuration:, environment:, project_scan:, limit: nil, seed: 1, oracle: nil,
                     site_selector: :biteable, base_scope: nil)
        # rubocop:enable Metrics/ParameterLists
        @environment = environment
        @limit = limit
        @seed = seed
        @site_selector = site_selector
        @base_scope = base_scope
        @oracle = oracle || DiagnosticOracle.new(
          configuration: configuration, environment: environment, project_scan: project_scan
        )
      end

      # @param path [String] the file to measure (used as the in-memory bind path)
      # @param source [String, nil] the file's source; read from disk when nil
      # @return [FileResult]
      def scan_file(path, source: nil)
        source ||= File.read(path, encoding: Encoding::UTF_8)
        kept = kept_mutations(source, path)
        return FileResult.new(path: path, killed: 0, survived: 0, sites: []) if kept.empty?

        baseline = @oracle.baseline(source: source, path: path)
        killed = 0
        sites = []
        kept.each do |mut|
          case classify(source, path, mut, baseline)
          when :killed then killed += 1
          when :survived then sites << surviving_site(mut)
            # :invalid — a parse-broken mutant; not a measurement, skip it.
          end
        end
        FileResult.new(path: path, killed: killed, survived: sites.size, sites: sites)
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

        baseline = @oracle.baseline(source: source, path: path)
        type_killed = 0
        test_killed = 0
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
            # :invalid — a parse-broken mutant; not a measurement, skip it.
          end
        end
        FusedFileResult.new(path: path, type_killed: type_killed, test_killed: test_killed, sites: sites)
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

      def classify(source, path, mut, baseline)
        mutant_source = mut.apply(source)
        return :invalid unless Prism.parse(mutant_source).success?

        @oracle.killed?(mutant_source: mutant_source, path: path, baseline: baseline) ? :killed : :survived
      rescue StandardError
        # A harness-level failure on one mutant must not abort the file.
        :invalid
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
