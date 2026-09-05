# frozen_string_literal: true

require "tempfile"

require_relative "../analysis/buffer_binding"
require_relative "../analysis/runner"
require_relative "../inference/fork_map"
require_relative "analysis_guard"
require_relative "diagnostic_oracle"
require_relative "discovery_seed"
require_relative "kill_signature"

module Rigor
  module Protection
    # Issue #254 — the ADR-69 Seam 1 kill oracle that judges a mutant by the WHOLE dependent closure.
    #
    # {DiagnosticOracle} re-analyses the mutated file alone, so the most valuable catch Rigor delivers is
    # scored as a miss: change what a method returns and the diagnostic lands in its *callers*, which is
    # exactly the cross-file reach the analyzer exists for. This oracle counts a kill when a new diagnostic
    # (against the clean baseline of the same file set) appears anywhere in `{mutated} ∪ dependents[mutated]`
    # — the ADR-46 reverse edge, supplied by {DependencyClosure}.
    #
    # **It is strictly additive, by construction.** The mutated file's verdict is delegated to a real
    # {DiagnosticOracle}, built with exactly the knowledge the shipped oracle would have had (the
    # `discovery-seeded-mutation-sites` seed when that feature is adopted, nothing when it is not), and only
    # when that says "survived" is the closure consulted. So this feature moves `killed` in ONE direction and
    # cannot silently re-decide a mutant the current oracle already kills. That separation is deliberate: what
    # the oracle KNOWS is #253/#260's axis, and mixing the two here made the measurement uninterpretable —
    # on redmine `app/models` an early build lost 11 kills to the richer knowledge while gaining none from the
    # closure, and the two effects were indistinguishable in the total.
    #
    # **The mutant's bytes are never on the measured file's disk.** For the closure half they are written to a
    # block-scoped temp file and bound to the measured path through {Analysis::BufferBinding} — the #146
    # editor seam, whose whole purpose is "analyse THESE bytes at THAT logical path". The binding reaches three
    # places that would otherwise read the file as it sits on disk:
    #
    # 1. the per-file parse (`Runner#parse_source` resolves through the binding);
    # 2. the discovery tables the dependents resolve the mutated `def`s through
    #    ({DiscoverySeed.tables_for_buffer} — the change-detection half: the mutated path's digest is the
    #    mutant's, so its bundle is invalidated and re-walked);
    # 3. diagnostic locations, which stay on the LOGICAL path, so a signature computed against a mutant is
    #    comparable with the baseline's.
    #
    # Miss any of them and every dependent reads the clean bytes, no diagnostic ever appears outside the
    # mutated file, and the run reports a plausible number that measured nothing new.
    #
    # Cost. The closure is consulted only for the mutants the mutated file did not already kill (≈30% of them
    # on Rigor's own `lib`), and each costs one analysis per dependent (mean 1.85 there) plus a ≈15ms seed
    # re-fold. Every per-mutant analysis keeps `cache_store: nil`: a `--threshold` CI gate must never be
    # handed a stale clean hit.
    class ClosureKillOracle
      # The clean baseline of one measured file, kept as TWO sets rather than their union. The mutated file's
      # half must be compared against exactly what the single-file oracle would compare against — a diagnostic
      # the closure baseline happens to carry at the mutated path (it analyses that file under cross-file
      # knowledge the single-file run does not have) must not mask a kill the shipped oracle would report.
      Baseline = Data.define(:own, :dependents)

      # @param environment [Rigor::Environment] built once by the caller.
      # @param project_scan [Rigor::Analysis::ProjectScan] built once by the caller; adopted per analysis
      #   through `prebuilt:`, exactly as {DiagnosticOracle} does.
      # @param paths [Array<String>] the measured file set, in canonical order (the seed's span: a class
      #   declared outside it stays unknown, as it does for Tier 1's seed and for {DiscoverySeed}).
      # @param dependents [Hash{String => Array<String>}] {DependencyClosure} map, restricted to `paths`.
      # @param seed_bundles [Hash{String => Hash}] {DiscoverySeed.bundles} over the same `paths`.
      # @param discovery_seed [Hash, nil] the `discovery-seeded-mutation-sites` seed when that feature is also
      #   adopted, nil otherwise. It goes to the delegated {DiagnosticOracle} verbatim, so the mutated file's
      #   verdict is byte-for-byte the verdict that feature combination produces without this one; its
      #   `param_inferred_types` slot additionally rides the per-mutant closure seed, so an admitted site is
      #   judged with the knowledge that admitted it (issue #260's amended decision). The table is not
      #   refreshed per mutant — the collector is a whole-project pre-pass, and one mutated method body does
      #   not justify re-running it thousands of times.
      def initialize(configuration:, environment:, project_scan:, paths:, dependents:, seed_bundles:,
                     discovery_seed: nil)
        @configuration = configuration
        @environment = environment
        @project_scan = project_scan
        @paths = paths
        @dependents = dependents
        @seed_bundles = seed_bundles
        @discovery_seed = discovery_seed
        @param_inferred_types = discovery_seed && discovery_seed[:param_inferred_types]
        @single = DiagnosticOracle.new(
          configuration: configuration, environment: environment, project_scan: project_scan,
          discovery_seed: discovery_seed
        )
      end

      # The clean baselines a mutant must add a diagnostic to: the mutated file's (the shipped oracle's own,
      # unchanged) and the dependents'. Computed once per measured file by the caller ({MutationScanner}),
      # never per mutant. The dependents' half is bound through the same buffer machinery a mutant is, so the
      # clean and mutant runs of the closure differ in exactly one input — the bytes.
      def baseline(source:, path:)
        Baseline.new(
          own: @single.baseline(source: source, path: path),
          dependents: dependents_signatures(source, path)
        )
      end

      # Killed iff the mutant introduces a diagnostic the baseline did not carry — in the mutated file (the
      # shipped verdict), or, failing that, in any dependent of it (what this feature adds).
      def killed?(mutant_source:, path:, baseline:)
        return true if @single.killed?(mutant_source: mutant_source, path: path, baseline: baseline.own)

        dependents = @dependents[path] || []
        return false if dependents.empty?

        dependents_signatures(mutant_source, path).any? { |sig| !baseline.dependents.include?(sig) }
      end

      # The file set a kill is looked for in: the mutated file plus its measured dependents.
      def closure_for(path)
        [path, *(@dependents[path] || [])]
      end

      private

      # The diagnostic signatures the dependents of `path` report while `source` stands in for it. Empty (and
      # analysis-free) when nothing depends on the file — 120 of Rigor's own 349 `lib` files.
      def dependents_signatures(source, path)
        dependents = @dependents[path] || []
        return Set.new if dependents.empty?

        with_mutant(source, path) do |buffer, seed|
          KillSignature.signatures_of(analyse(dependents, buffer, seed))
        end
      end

      # Binds `source` to `path` for the duration of the block, yielding the binding and the seed tables
      # rebuilt against it.
      #
      # The mutant's bytes live in a **block-scoped** temp file: created and unlinked inside this method, so
      # the oracle holds no file between calls and no caller needs a teardown hook to reclaim one. Issue #572
      # — the previous design kept one `Tempfile` per process, which `Tempfile` reclaims only from its
      # finalizer, i.e. at GC time. That made the file's disappearance a timing coin flip: the spec suite's
      # issue-#330 residue check runs while the process is still alive, so it saw a live `rigor-mutant-*.rb`
      # and failed a CI shard that the identical head passed on rerun.
      #
      # Per-mutant rather than per-process is safe on both axes the per-process comment defended. Freshness:
      # the digest that invalidates the mutated file's discovery bundle is taken over the file's CONTENT and
      # the bundles are keyed by the LOGICAL path, so nothing depends on the physical name being stable — a
      # name that is never reused is strictly further from a stale answer than one rewritten in place. Cost:
      # one `mkstemp` + `unlink` against the whole analysis-per-dependent this call already runs.
      #
      # The directory stays {Inference::ForkMap.child_scratch_dir}, and that is not redundant. A
      # {CLI::MutationForkScan} worker unwinds this block on both paths it can take on its own — a normal
      # return and the `StandardError` {Inference::ForkMap.run_worker} rescues — but a worker killed by a
      # signal unwinds nothing, and its `exit!` runs neither `at_exit` nor a finalizer. The parent's fork
      # tmpdir stays the backstop for exactly that case (issue #330); on the parent and on the sequential
      # path the reader answers `nil`, which is `Tempfile.create`'s own default.
      def with_mutant(source, path)
        Tempfile.create(["rigor-mutant-", ".rb"], Inference::ForkMap.child_scratch_dir) do |file|
          file.binmode
          file.write(source)
          file.flush
          buffer = Analysis::BufferBinding.new(logical_path: path, physical_path: file.path)
          yield(buffer, seed_for(buffer))
        end
      end

      def seed_for(buffer)
        tables = DiscoverySeed.tables_for_buffer(paths: @paths, bundles: @seed_bundles, buffer: buffer)
        return tables if @param_inferred_types.nil? || @param_inferred_types.empty?

        tables.merge(param_inferred_types: @param_inferred_types).freeze
      end

      # One analysis of `paths` with the mutant bound. `prebuilt:` keeps the RBS environment + whole-project
      # pre-pass the caller paid for once; `discovery_seed:` (issue #260's runner seam) is what carries the
      # cross-file knowledge into a prebuilt run, and here it is the MUTANT-refreshed table set — without it a
      # dependent resolves the `def` still on disk and no mutation could ever be visible to it.
      #
      # `analyze_only:` is load-bearing, not an optimisation. A `buffer:` alone selects editor-mode option A,
      # whose analysed set IS the buffer's single logical path — every other file is read by the pre-passes
      # and emits nothing. A closure oracle built that way would report zero cross-file kills and look
      # entirely plausible doing it. Passing both selects option B (#146), where the closure wins and the
      # buffer is one member of it.
      #
      # Issue #686 — the guard is on this line for the reason the whole class exists. `killed?` decides by
      # SET DIFFERENCE between the baseline's signatures and the mutant's, and a crashed check rule makes
      # both sides the same deterministic `internal analyzer error` row on the same file: the difference is
      # empty and the mutant is scored a survivor, not "indeterminate". Every mutant in the file scores the
      # same way, which inflates the survivor count the harness reports as its headline signal.
      def analyse(paths, buffer, seed)
        AnalysisGuard.checked(
          Analysis::Runner.new(
            configuration: @configuration, environment: @environment, prebuilt: @project_scan,
            cache_store: nil, collect_stats: false, buffer: buffer, discovery_seed: seed, analyze_only: paths
          ).run(paths),
          context: "ClosureKillOracle closure analysis of #{paths.join(', ')}"
        )
      end
    end
  end
end
