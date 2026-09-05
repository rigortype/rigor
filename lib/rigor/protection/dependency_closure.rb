# frozen_string_literal: true

require_relative "../analysis/runner"

module Rigor
  module Protection
    # Issue #254 — the **dependent closure** the Tier-2 kill oracle re-analyses: for each measured file, the
    # measured files that read a declaration or a method body from it.
    #
    # ADR-46 already records exactly this edge, but only under `record_dependencies: true` — an ordinary
    # analysis (and every per-mutant analysis) records nothing. So the map is built ONCE, by one recording
    # pass over the measured paths, and then read for every mutant. This is the one place ADR-46's REVERSE
    # index is the right tool (the forward edge is a cache-key input; #134 needs that one).
    #
    # Cost, measured on Rigor's own `lib` (349 files, 8 workers, warm cache): ≈4.3s for the recording pass —
    # roughly one extra `rigor check` next to a multi-minute mutation run, paid once. The pass CANNOT reuse
    # the caller's `prebuilt:` {Analysis::ProjectScan}: `Runner#ensure_project_discovery` is a no-op under
    # `prebuilt:`, so a prebuilt recording run would resolve nothing cross-file and record an empty graph —
    # a silently empty closure, which is precisely the failure mode this feature exists to remove. It
    # therefore runs its own pre-passes, sharing only the environment and the (read-only) cache store.
    #
    # Not fail-soft on purpose: an exception here aborts the run rather than degrading the measurement to
    # "no dependents", which would look exactly like a plausible effectiveness number.
    module DependencyClosure
      module_function

      # @param paths [Array<String>] the measured file set, in caller order.
      # @param environment [Rigor::Environment] built once by the caller.
      # @param cache_store [Rigor::Cache::Store, nil] threaded to the recording run only (its RBS-env and
      #   plugin-producer tiers); the per-mutant analyses stay `cache_store: nil` regardless.
      # @param workers [Integer] fork-pool workers for the recording pass (the pool records per worker and
      #   marshals the records back, so a pooled graph equals the sequential one).
      # @return [Hash{String => Array<String>}] frozen `path => sorted dependents`, restricted to `paths`.
      def build(paths:, configuration:, environment:, cache_store: nil, workers: 0)
        runner = Analysis::Runner.new(
          configuration: configuration, environment: environment, cache_store: cache_store,
          collect_stats: false, record_dependencies: true, workers: workers
        )
        runner.run(paths)
        index(runner.file_dependents, paths)
      end

      # Restricts a raw {Analysis::Runner#file_dependents} map to the measured set: a dependent outside it is
      # not being measured, so re-analysing it would report a diagnostic against a file the run never
      # baselined. Self-edges are dropped (the mutated file is the closure's own head), and each list is
      # sorted so a `--threshold` gate reads the same number whatever order the recording pass finished in.
      def index(dependents, paths)
        measured = Set.new(paths)
        paths.to_h do |path|
          list = (dependents[path] || []).select { |dep| measured.include?(dep) && dep != path }
          [path, list.sort.freeze]
        end.freeze
      end
    end
  end
end
