# frozen_string_literal: true

require "rigor/plugin"

require_relative "sidekiq/worker_index"
require_relative "sidekiq/worker_discoverer"
require_relative "sidekiq/schedule_scan"
require_relative "sidekiq/analyzer"
require_relative "sidekiq/effects"

module Rigor
  module Plugin
    # rigor-sidekiq — validates `Worker.perform_async(...)` / `.perform_in(...)` / `.perform_at(...)` /
    # `.perform_inline(...)` argument arity against the discovered `#perform` definitions.
    #
    # Tier 3C of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Statically discovers Sidekiq workers by walking `worker_search_paths` and parsing each file with
    # Prism — no `sidekiq` runtime dependency.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-sidekiq
    #         config:
    #           worker_search_paths: ["app/workers", "app/sidekiq"]   # default; optional
    #           worker_marker_modules: ["Sidekiq::Job", "Sidekiq::Worker"]  # default; optional
    #           schedule_paths: ["config/schedule.yml", "config/sidekiq.yml"]  # default; optional
    #
    # ## What it checks
    #
    # 1. **Argument arity** — `perform_async(args)` / `perform_inline(args)` forward every argument to
    #    `#perform`; `perform_in(t, args)` / `perform_at(t, args)` consume the first argument as the
    #    schedule and forward the rest. Mismatches emit `wrong-arity`.
    # 2. **Missing schedule** — `perform_in()` / `perform_at()` with zero arguments emit `missing-schedule`.
    #
    # ## What it contributes to `rigor unused`
    #
    # The workers a schedule file names under `class:` and nothing else (ADR-102 WD3 / #367) — see
    # {#prepare} and {ScheduleScan}.
    #
    # ## Limitations (v0.1.0)
    #
    # - Direct `include` matches only against the configured marker modules. Indirect includes via a
    #   custom concern are out of scope.
    # - `#perform` arity is read from the syntactic parameter list. `define_method` actions are out of scope.
    # - Required keyword arguments are not validated at the call site (positional-only for v0.1.0).
    #   Sidekiq serialises arguments to JSON, so keyword args are uncommon in practice.
    # - The schedule argument's type isn't validated (no "is this a Time?" check); we just consume it.
    class Sidekiq < Rigor::Plugin::Base
      manifest(
        id: "sidekiq",
        # Bumped 2026-08-16 — publishes `:reachability_roots` for `rigor unused` (ADR-102 WD3): the workers
        # a schedule file enqueues by name, which no `perform_async` call site writes down.
        version: "0.2.0",
        description: "Validates Sidekiq `Worker.perform_async` argument arity.",
        config_schema: {
          "worker_search_paths" => { kind: :array, default: ["app/workers", "app/sidekiq"] },
          "worker_marker_modules" => { kind: :array, default: %w[Sidekiq::Job Sidekiq::Worker] },
          # `schedule_paths` — the schedule configuration {ScheduleScan} reads for the reachability roots
          # below. The two defaults are the conventional locations of the two schedule layouts in the wild:
          # `sidekiq-cron`'s `config/schedule.yml` and `sidekiq-scheduler`'s `:scheduler: :schedule:` block
          # inside `config/sidekiq.yml`. A project that keeps its schedule elsewhere lists the file itself;
          # these are file paths, not directories, because a schedule is a named document rather than a tree.
          "schedule_paths" => { kind: :array, default: ["config/schedule.yml", "config/sidekiq.yml"] }
        },
        produces: [:reachability_roots],
        # ADR-103 WD4 / WD10 (#456). The rows themselves are NOT here: they key on the project's own
        # `worker_marker_modules:` setting, so they are built in `#effect_attributions` below.
        effect_labels: []
      )

      # ADR-103 WD10 — the enqueue rows, keyed on whichever modules this project's workers include.
      # Overridden rather than declared on the manifest because the marker set is configuration;
      # `Plugin::Registry#effect_contributions` is lazy and asks once per process, and only on a run with
      # collection on.
      def effect_attributions
        Effects.attributions(@worker_marker_modules || Array(config.fetch("worker_marker_modules")).map(&:to_s))
      end

      producer :worker_index, watch: -> { [[@worker_search_paths, "**/*.rb"]] } do |_params|
        WorkerDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @worker_search_paths,
          marker_modules: @worker_marker_modules
        ).discover
      end

      # Cached separately from `:worker_index` because the two invalidate on different files: editing a
      # schedule changes which workers are reached without touching `app/workers` at all. The `watch:` roots
      # the glob at the working directory so that CREATING a schedule file — not just editing one — is seen.
      producer :scheduled_workers, watch: -> { [[".", *@schedule_paths]] } do |_params|
        ScheduleScan.new(
          io_boundary: io_boundary,
          schedule_paths: @schedule_paths
        ).worker_names
      end

      def init(_services)
        @worker_search_paths = Array(config.fetch("worker_search_paths")).map(&:to_s)
        @worker_marker_modules = Array(config.fetch("worker_marker_modules")).map(&:to_s)
        @schedule_paths = Array(config.fetch("schedule_paths")).map(&:to_s)
      end

      # ADR-102 WD3 — publishes the workers a schedule file enqueues BY NAME, for `rigor unused`.
      #
      # `MyWorker.perform_async(...)` writes the worker's name as an ordinary constant, so the report's scan
      # already records that edge and a root would add nothing. A worker named only as the string
      # `class: "MyWorker"` in `config/schedule.yml` is the opposite case: it runs every night and the
      # constant appears nowhere, so it reads as dead.
      #
      # The intersection is what keeps the contribution honest, exactly as in `rigor-pundit`. {ScheduleScan}
      # says which names the schedule WRITES; {WorkerDiscoverer} says which workers EXIST. A `class:` value
      # matching no discovered worker — a typo, a renamed class, a job living outside `worker_search_paths` —
      # is dropped rather than published, so the failure mode is a missing root (a candidate row a human can
      # judge) instead of a spurious one (silence where dead code used to be).
      #
      # Publishing the discovered worker set instead would have been one line and is what this refuses to do:
      # "a file exists under `app/workers`" is not evidence that anything enqueues it.
      def prepare(services)
        index = producer_value(:worker_index)
        scheduled = producer_value(:scheduled_workers)
        return if index.nil? || scheduled.nil?

        roots = scheduled.select { |name| index.known?(name) }
        return if roots.empty?

        services.fact_store.publish(plugin_id: manifest.id, name: :reachability_roots, value: roots)
      end

      # File-level only: the load-error emission. The per-call arity validation runs over the engine-owned
      # walk via the node_rule below (ADR-37). The worker index is lazily loaded + memoised by
      # `producer_value`, shared by both surfaces.
      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = producer_value(:worker_index)
        return [load_error_diagnostic(path)] if index.nil? && producer_error(:worker_index)

        []
      end

      node_rule Prism::CallNode do |node, _scope, path|
        index = producer_value(:worker_index)
        next [] if index.nil? || index.empty?

        diagnostics_for(Analyzer.violations_for(call_node: node, worker_index: index), path: path, node: node)
      end

      private

      def load_error_diagnostic(path)
        error = producer_error(:worker_index)
        Rigor::Analysis::Diagnostic.new(
          path: path, line: 1, column: 1,
          message: "rigor-sidekiq: failed to discover workers: #{error.class}: #{error.message}",
          severity: :warning,
          rule: "load-error"
        )
      end
    end

    Rigor::Plugin.register(Sidekiq)
  end
end
