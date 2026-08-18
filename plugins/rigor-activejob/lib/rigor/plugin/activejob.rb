# frozen_string_literal: true

require "rigor/plugin"

require_relative "activejob/job_index"
require_relative "activejob/job_discoverer"
require_relative "activejob/analyzer"
require_relative "activejob/effects"
require_relative "activejob/recurring_scan"

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
    #           recurring_paths: ["config/recurring.yml"]        # default; optional
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
        # Bumped — publishes `:reachability_roots` for `rigor unused` (ADR-102 WD3): the jobs Solid Queue's
        # recurring schedule runs by name, which no `perform_later` call site writes down.
        version: "0.2.0",
        description: "Validates ActiveJob `Job.perform_later` argument arity.",
        config_schema: {
          "job_search_paths" => { kind: :array, default: ["app/jobs"] },
          "job_base_classes" => { kind: :array, default: %w[ApplicationJob ActiveJob::Base] },
          # `recurring_paths` — the schedule configuration {RecurringScan} reads for the reachability roots
          # below. The default is Solid Queue's conventional location, the Active Job backend Rails ships by
          # default from 8.0. A project that keeps its schedule elsewhere lists the file itself; these are
          # file paths, not directories, because a schedule is a named document rather than a tree.
          "recurring_paths" => { kind: :array, default: ["config/recurring.yml"] }
        },
        produces: [:reachability_roots],
        # ADR-103 WD4 / WD10 (#387). The rows themselves are NOT here: they depend on
        # `config.active_job.queue_adapter`, which is a project fact, so they are built in
        # `#effect_attributions` below. `effect_root: "rails"` is granted because the engine bundles this
        # plugin ({Rigor::Plugin::FirstParty}); a third-party plugin declaring it would open `activejob.*`.
        effect_root: "rails",
        effect_labels: ["rails.activejob.enqueue"],
        effect_entry_points: Effects.entry_points
      )

      # ADR-103 WD10 — the enqueue's transport, read off the project's own configuration. Overridden rather
      # than declared on the manifest because the answer is per project; memoised because
      # `Plugin::Registry#effect_contributions` is lazy and asks once per process, and only on a run with
      # collection on — a `rigor check` with no `effects:` block never opens `config/application.rb` for this.
      def effect_attributions
        Effects.attributions(detected_queue_adapter)
      end

      def effect_edges
        Effects.edges(detected_queue_adapter)
      end

      def detected_queue_adapter
        return @detected_queue_adapter if defined?(@detected_queue_adapter)

        @detected_queue_adapter = Effects.detect_adapter(io_boundary, Dir.pwd)
      end

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

      # Cached separately from `:job_index` because the two invalidate on different files: editing a
      # schedule changes which jobs are reached without touching `app/jobs` at all. The `watch:` roots the
      # glob at the working directory so that CREATING a schedule file — not just editing one — is seen.
      producer :recurring_jobs, watch: -> { [[".", *@recurring_paths]] } do |_params|
        RecurringScan.new(
          io_boundary: io_boundary,
          recurring_paths: @recurring_paths
        ).job_names
      end

      def init(_services)
        @job_search_paths = Array(config.fetch("job_search_paths")).map(&:to_s)
        @job_base_classes = Array(config.fetch("job_base_classes")).map(&:to_s)
        @recurring_paths = Array(config.fetch("recurring_paths")).map(&:to_s)
      end

      # ADR-102 WD3 — publishes the jobs Solid Queue's recurring schedule runs BY NAME, for `rigor unused`.
      #
      # The intersection is what keeps the contribution honest, exactly as in `rigor-sidekiq` and
      # `rigor-pundit`. {RecurringScan} says which names the schedule WRITES; {JobIndex} says which jobs
      # EXIST. A `class:` value matching no discovered job — a typo, a renamed class, a job living outside
      # `job_search_paths` — is dropped rather than published, so the failure mode is a missing root (a
      # candidate row a human can judge) instead of a spurious one (silence where dead code used to be).
      def prepare(services)
        index = producer_value(:job_index)
        scheduled = producer_value(:recurring_jobs)
        return if index.nil? || scheduled.nil?

        roots = scheduled.select { |name| index.known?(name) }
        return if roots.empty?

        services.fact_store.publish(plugin_id: manifest.id, name: :reachability_roots, value: roots)
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
