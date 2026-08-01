# frozen_string_literal: true

require "tempfile"

require_relative "../analysis/buffer_binding"
require_relative "../analysis/runner"
require_relative "discovery_seed"
require_relative "kill_signature"

module Rigor
  module Protection
    # Issue #254 — the ADR-69 Seam 1 kill oracle that judges a mutant by the WHOLE dependent closure.
    #
    # {DiagnosticOracle} re-analyses the mutated file alone, so the most valuable catch Rigor delivers is
    # scored as a miss: change what a method returns and the diagnostic lands in its *callers*, which is
    # exactly the cross-file reach the analyzer exists for. This oracle counts a kill when a NEW diagnostic
    # (against the clean baseline of the same file set) appears anywhere in `{mutated} ∪ dependents[mutated]`
    # — the ADR-46 reverse edge, supplied by {DependencyClosure}.
    #
    # **The mutant's bytes are never on the measured file's disk.** They are written to a process-private
    # temp file and bound to the measured path through {Analysis::BufferBinding} — the #146 editor seam,
    # whose whole purpose is "analyse THESE bytes at THAT logical path". The binding reaches three places
    # that would otherwise read the file as it sits on disk:
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
    # Cost. A kill is decided in two phases: the mutated file first (the {DiagnosticOracle} cost, plus the
    # per-mutant seed fold), and the dependents only when that found nothing. Per-file analysis is
    # independent given one seed, so the phased answer is the single-run answer — while the ≈70% of mutants
    # the mutated file already kills never pay for the closure at all. The remaining survivors pay one extra
    # analysis per dependent (mean 1.85 on Rigor's own `lib`).
    #
    # Every per-mutant analysis keeps `cache_store: nil`: a `--threshold` CI gate must never be handed a
    # stale clean hit.
    class ClosureKillOracle
      # @param configuration [Rigor::Configuration]
      # @param environment [Rigor::Environment] built once by the caller.
      # @param project_scan [Rigor::Analysis::ProjectScan] built once by the caller; adopted per analysis
      #   through `prebuilt:`, exactly as {DiagnosticOracle} does.
      # @param paths [Array<String>] the measured file set, in canonical order (the seed's span: a class
      #   declared outside it stays unknown, as it does for Tier 1's seed and for {DiscoverySeed}).
      # @param dependents [Hash{String => Array<String>}] {DependencyClosure} map, restricted to `paths`.
      # @param seed_bundles [Hash{String => Hash}] {DiscoverySeed.bundles} over the same `paths`.
      # @param param_inferred_types [Hash, nil] the ADR-67 WD3 table from the `discovery-seeded-mutation-sites`
      #   seed when that feature is also adopted, carried verbatim. Issue #260's amended decision: the oracle
      #   holds the SAME knowledge the site filter admitted a site on. It is not refreshed per mutant — the
      #   collector is a whole-project pre-pass, and a mutation inside one method body moves nobody's inferred
      #   parameter enough to justify re-running it thousands of times.
      def initialize(configuration:, environment:, project_scan:, paths:, dependents:, seed_bundles:,
                     param_inferred_types: nil)
        @configuration = configuration
        @environment = environment
        @project_scan = project_scan
        @paths = paths
        @dependents = dependents
        @seed_bundles = seed_bundles
        @param_inferred_types = param_inferred_types
      end

      # The clean baseline: every diagnostic signature the closure carries on unmutated code. Computed once
      # per measured file by the caller ({MutationScanner}), never per mutant.
      #
      # `source` is bound through the same buffer machinery a mutant is, so the baseline and the mutant runs
      # differ in exactly one input — the bytes — and nothing else can drift between them.
      def baseline(source:, path:)
        with_mutant(source, path) do |buffer, seed|
          KillSignature.signatures_of(analyse(closure_for(path), buffer, seed))
        end
      end

      # Killed iff the mutant introduces a diagnostic the closure baseline did not carry — in the mutated
      # file, or in any dependent of it.
      def killed?(mutant_source:, path:, baseline:)
        with_mutant(mutant_source, path) do |buffer, seed|
          next true if new_diagnostic?(analyse([path], buffer, seed), baseline)

          dependents = @dependents[path] || []
          !dependents.empty? && new_diagnostic?(analyse(dependents, buffer, seed), baseline)
        end
      end

      # The file set a kill is looked for in: the mutated file plus its measured dependents.
      def closure_for(path)
        [path, *(@dependents[path] || [])]
      end

      private

      # Binds `source` to `path` for the duration of the block, yielding the binding and the seed tables
      # rebuilt against it. One temp file per process (never per mutant): the digest that invalidates the
      # mutated file's bundle is taken over the file's CONTENT, and the per-run digest memo is not installed
      # out here, so rewriting one path in place cannot serve a stale answer.
      def with_mutant(source, path)
        File.binwrite(mutant_file.path, source)
        buffer = Analysis::BufferBinding.new(logical_path: path, physical_path: mutant_file.path)
        yield(buffer, seed_for(buffer))
      end

      # The process-private mutant file. Created lazily, and re-created after a fork ({CLI::MutationForkScan}
      # workers must not share one path), which the pid guard detects.
      def mutant_file
        return @mutant_file if @mutant_file && @mutant_pid == Process.pid

        @mutant_pid = Process.pid
        @mutant_file = Tempfile.new(["rigor-mutant-", ".rb"])
      end

      def seed_for(buffer)
        tables = DiscoverySeed.tables_for_buffer(paths: @paths, bundles: @seed_bundles, buffer: buffer)
        return tables if @param_inferred_types.nil? || @param_inferred_types.empty?

        tables.merge(param_inferred_types: @param_inferred_types).freeze
      end

      # One analysis of `paths` with the mutant bound. `prebuilt:` keeps the RBS environment + whole-project
      # pre-pass the caller paid for once; `discovery_seed:` (issue #260's runner seam) is what carries the
      # cross-file knowledge into a prebuilt run, and here it is the MUTANT-refreshed table set.
      #
      # `analyze_only:` is load-bearing, not an optimisation. A `buffer:` alone selects editor-mode option A,
      # whose analysed set IS the buffer's single logical path — every other file is read by the pre-passes
      # and emits nothing. A closure oracle built that way would report zero cross-file kills and look
      # entirely plausible doing it. Passing both selects option B (#146), where the closure wins and the
      # buffer is one member of it.
      def analyse(paths, buffer, seed)
        Analysis::Runner.new(
          configuration: @configuration, environment: @environment, prebuilt: @project_scan,
          cache_store: nil, collect_stats: false, buffer: buffer, discovery_seed: seed, analyze_only: paths
        ).run(paths).diagnostics
      end

      def new_diagnostic?(diagnostics, baseline)
        diagnostics.any? { |diagnostic| !baseline.include?(KillSignature.of(diagnostic)) }
      end
    end
  end
end
