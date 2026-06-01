# frozen_string_literal: true

require "rigor/plugin"

require_relative "activejob/job_index"
require_relative "activejob/job_discoverer"
require_relative "activejob/analyzer"

module Rigor
  module Plugin
    # rigor-activejob — validates `Job.perform_later(...)` /
    # `.perform_now(...)` / `.perform(...)` argument arity
    # against the discovered `#perform` definitions.
    #
    # Tier 1D of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Statically discovers ActiveJob subclasses by walking
    # the configured `job_search_paths` and parsing each
    # file with Prism — no `active_job` runtime dependency.
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
    # - Direct-superclass match only. `class WelcomeJob <
    #   BaseJob` where `BaseJob < ApplicationJob` is NOT
    #   discovered. Add `BaseJob` to `job_base_classes` if
    #   needed.
    # - The `#perform` arity is read from the syntactic
    #   parameter list. Methods built via `define_method`
    #   are out of scope.
    # - Required keyword arguments are recognised but not
    #   validated at the call site (positional arity only
    #   for v0.1.0).
    class Activejob < Rigor::Plugin::Base
      manifest(
        id: "activejob",
        version: "0.1.0",
        description: "Validates ActiveJob `Job.perform_later` argument arity.",
        config_schema: {
          "job_search_paths" => :array,
          "job_base_classes" => :array
        }
      )

      DEFAULT_JOB_SEARCH_PATHS = ["app/jobs"].freeze
      DEFAULT_JOB_BASE_CLASSES = %w[ApplicationJob ActiveJob::Base].freeze

      # Cached: discovered job index. The producer reads every
      # file under `job_search_paths` via the trusted
      # `IoBoundary`; the descriptor's auto-collected
      # `FileEntry` digests invalidate the cache when any of
      # those files change.
      producer :job_index do |_params|
        JobDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @job_search_paths,
          base_classes: @job_base_classes
        ).discover
      end

      def init(_services)
        @job_search_paths = Array(config.fetch("job_search_paths", DEFAULT_JOB_SEARCH_PATHS)).map(&:to_s)
        @job_base_classes = Array(config.fetch("job_base_classes", DEFAULT_JOB_BASE_CLASSES)).map(&:to_s)
        @job_index = nil
        @load_error = nil
      end

      # File-level only: the load-error emission. Per-call arity
      # validation runs over the engine-owned walk via the node_rule
      # below (ADR-37). The job index is lazily loaded + memoised by
      # job_index_or_nil, shared by both surfaces.
      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = job_index_or_nil
        return [load_error_diagnostic(path)] if index.nil? && @load_error

        []
      end

      node_rule Prism::CallNode do |node, _scope, path|
        index = job_index_or_nil
        next [] if index.nil? || index.empty?

        Analyzer.violations_for(call_node: node, job_index: index).map do |violation|
          diagnostic(node, path: path, message: violation.message, severity: violation.severity, rule: violation.rule)
        end
      end

      private

      def job_index_or_nil
        return @job_index if @job_index

        # Read-then-cache pattern: the discoverer's
        # IoBoundary reads happen INSIDE `discover`, which is
        # invoked through `cache_for`'s producer block. The
        # boundary's accumulated FileEntry digests get
        # captured into the descriptor at cache_for time.
        @job_index = cache_for(:job_index, params: {}).call
      rescue StandardError => e
        @load_error = "rigor-activejob: failed to discover jobs: #{e.class}: #{e.message}"
        nil
      end

      def load_error_diagnostic(path)
        Rigor::Analysis::Diagnostic.new(
          path: path, line: 1, column: 1,
          message: @load_error,
          severity: :warning,
          rule: "load-error"
        )
      end
    end

    Rigor::Plugin.register(Activejob)
  end
end
