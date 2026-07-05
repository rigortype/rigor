# frozen_string_literal: true

require "rigor/plugin"

require_relative "activejob/job_index"
require_relative "activejob/job_discoverer"
require_relative "activejob/analyzer"

module Rigor
  module Plugin
    # rigor-activejob — validates `Job.perform_later(...)` / `.perform_now(...)` / `.perform(...)`
    # argument arity against the discovered `#perform` definitions.
    #
    # Tier 1D of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Statically discovers ActiveJob subclasses by walking the configured `job_search_paths` and
    # parsing each file with Prism — no `active_job` runtime dependency.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-activejob
    #         config:
    #           job_search_paths: ["app/jobs"]                  # default; optional
    #           job_base_classes: ["ApplicationJob", "ActiveJob::Base"]  # default; optional
    #
    # ## Limitations (v0.1.0)
    #
    # - Direct-superclass match only. `class WelcomeJob < BaseJob` where `BaseJob < ApplicationJob` is
    #   NOT discovered. Add `BaseJob` to `job_base_classes` if needed.
    # - The `#perform` arity is read from the syntactic parameter list. Methods built via
    #   `define_method` are out of scope.
    # - Required keyword arguments are recognised but not validated at the call site (positional arity
    #   only for v0.1.0).
    class Activejob < Rigor::Plugin::Base
      manifest(
        id: "activejob",
        version: "0.1.0",
        description: "Validates ActiveJob `Job.perform_later` argument arity.",
        config_schema: {
          "job_search_paths" => { kind: :array, default: ["app/jobs"] },
          "job_base_classes" => { kind: :array, default: %w[ApplicationJob ActiveJob::Base] }
        }
      )

      # Cached: discovered job index. `watch:` (ADR-60 WD3) covers every `.rb` under `job_search_paths`
      # so the cache invalidates when a job is added, removed, or edited; the discoverer's in-block
      # `IoBoundary` reads are captured into the record-and-validate dependency descriptor after the
      # block runs.
      producer :job_index, watch: -> { [[@job_search_paths, "**/*.rb"]] } do |_params|
        JobDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @job_search_paths,
          base_classes: @job_base_classes
        ).discover
      end

      def init(_services)
        @job_search_paths = Array(config.fetch("job_search_paths")).map(&:to_s)
        @job_base_classes = Array(config.fetch("job_base_classes")).map(&:to_s)
      end

      # File-level only: the load-error emission. Per-call arity validation runs over the engine-owned
      # walk via the node_rule below (ADR-37). The job index is lazily loaded + memoised by
      # `producer_value`, shared by both surfaces.
      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = producer_value(:job_index)
        return [load_error_diagnostic(path)] if index.nil? && producer_error(:job_index)

        []
      end

      node_rule Prism::CallNode do |node, _scope, path|
        index = producer_value(:job_index)
        next [] if index.nil? || index.empty?

        diagnostics_for(Analyzer.violations_for(call_node: node, job_index: index), path: path, node: node)
      end

      private

      def load_error_diagnostic(path)
        error = producer_error(:job_index)
        Rigor::Analysis::Diagnostic.new(
          path: path, line: 1, column: 1,
          message: "rigor-activejob: failed to discover jobs: #{error.class}: #{error.message}",
          severity: :warning,
          rule: "load-error"
        )
      end
    end

    Rigor::Plugin.register(Activejob)
  end
end
