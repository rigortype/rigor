# frozen_string_literal: true

require "rigor/plugin"

require_relative "sidekiq/worker_index"
require_relative "sidekiq/worker_discoverer"
require_relative "sidekiq/analyzer"

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
    #
    # ## What it checks
    #
    # 1. **Argument arity** — `perform_async(args)` / `perform_inline(args)` forward every argument to
    #    `#perform`; `perform_in(t, args)` / `perform_at(t, args)` consume the first argument as the
    #    schedule and forward the rest. Mismatches emit `wrong-arity`.
    # 2. **Missing schedule** — `perform_in()` / `perform_at()` with zero arguments emit `missing-schedule`.
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
        version: "0.1.0",
        description: "Validates Sidekiq `Worker.perform_async` argument arity.",
        config_schema: {
          "worker_search_paths" => { kind: :array, default: ["app/workers", "app/sidekiq"] },
          "worker_marker_modules" => { kind: :array, default: %w[Sidekiq::Job Sidekiq::Worker] }
        }
      )

      producer :worker_index, watch: -> { [[@worker_search_paths, "**/*.rb"]] } do |_params|
        WorkerDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @worker_search_paths,
          marker_modules: @worker_marker_modules
        ).discover
      end

      def init(_services)
        @worker_search_paths = Array(config.fetch("worker_search_paths")).map(&:to_s)
        @worker_marker_modules = Array(config.fetch("worker_marker_modules")).map(&:to_s)
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
