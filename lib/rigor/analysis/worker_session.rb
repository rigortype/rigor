# frozen_string_literal: true

require "prism"

require_relative "../environment"
require_relative "../scope"
require_relative "../cache/store"
require_relative "../plugin"
require_relative "../rbs_extended/reporter"
require_relative "../reflection"
require_relative "../type/combinator"
require_relative "../inference/coverage_scanner"
require_relative "../inference/scope_indexer"
require_relative "../inference/method_dispatcher/file_folding"
require_relative "check_rules"
require_relative "dependency_source_inference"
require_relative "diagnostic"

module Rigor
  module Analysis
    # ADR-15 Phase 4a — per-worker analysis substrate.
    # [ADR-15](../../../docs/adr/15-ractor-concurrency.md)
    # § Phase 4 carves the eventual Ractor-isolated worker pool
    # into three sub-phases; this is the substrate that 4b will
    # wrap in `Ractor.new` and 4c will gate behind
    # `RIGOR_RACTOR_WORKERS`. NO Ractor in the loop yet — 4a
    # exists so the per-worker ownership boundary is testable in
    # the absence of any Ractor coordination.
    #
    # The constructor takes only `Ractor.shareable?` inputs:
    #
    # - `configuration` — Phase 2a ({Rigor::Configuration} is
    #   `Ractor.shareable?`).
    # - `cache_store` — frozen-shareable handle is NOT a precondition;
    #   future 4b workers build their OWN Store at the shared
    #   `cache_root` directory. 4a accepts an already-built Store
    #   for the no-Ractor coordinator path.
    # - `plugin_blueprints` — Phase 3a
    #   (`Array<Plugin::Blueprint>` is `Ractor.shareable?`).
    # - `explain` — Boolean.
    #
    # Internally the session OWNS (and never shares):
    #
    # - {Rigor::Plugin::Services} bound to the per-worker Store.
    # - {Rigor::Plugin::Registry} materialised from the blueprints
    #   via {Rigor::Plugin::Registry.materialize}; each plugin
    #   instance, with its mutable per-run accumulators
    #   (`@reachable_absurd_nodes`, `*_index`, …) lives entirely
    #   inside this session.
    # - {Rigor::RbsExtended::Reporter} +
    #   {Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter}
    #   (Mutex-bearing; intentionally per-worker — the runner
    #   merges entries post-pool via {#drain_reporters}).
    # - {Rigor::Environment} threaded with the per-worker reporters
    #   so reporter writes from inference / dispatcher accumulate
    #   into the worker's own state.
    #
    # Plugin `prepare` runs ONCE at construction time so each
    # worker is "warm" by the time `#analyze` is first called. Any
    # raise from `prepare` is captured into {#prepare_diagnostics}
    # so the runner can surface them alongside the per-file
    # diagnostic stream.
    #
    # Equivalence contract (proven by spec): given identical
    # `(configuration, cache_store, plugin_blueprints)`, the
    # multiset of diagnostics from
    # `paths.flat_map { |p| session.analyze(p) }` plus
    # {#prepare_diagnostics} plus reporter drains MUST equal the
    # corresponding subset of {Rigor::Analysis::Runner#run}'s
    # output (modulo severity-profile re-stamping, which the
    # session leaves to the caller because it is a per-run
    # aggregate concern).
    class WorkerSession
      attr_reader :configuration, :cache_store, :services, :plugin_registry,
                  :dependency_source_index, :environment,
                  :rbs_extended_reporter, :boundary_cross_reporter,
                  :prepare_diagnostics

      # @param configuration [Rigor::Configuration]
      # @param cache_store [Rigor::Cache::Store, nil] persistent
      #   cache the session exposes to plugin-side producers and
      #   the RBS loader. Pass `nil` to disable caching.
      # @param plugin_blueprints [Array<Rigor::Plugin::Blueprint>]
      #   replay descriptors. Empty array yields a session with
      #   no plugin contributions.
      # @param explain [Boolean] when true, `#analyze` additionally
      #   emits one `:info` `fallback` diagnostic per
      #   directly-unrecognised node, mirroring
      #   {Rigor::Analysis::Runner#explain_diagnostics}.
      def initialize(configuration:, cache_store: nil,
                     plugin_blueprints: [], explain: false)
        @configuration = configuration
        @cache_store = cache_store
        @explain = explain

        # NOTE: `Inference::MethodDispatcher::FileFolding.fold_platform_specific_paths`
        # is process-global state. Writing it from a non-main
        # Ractor would raise `Ractor::IsolationError`, so the
        # session does NOT touch it — the CALLER (typically
        # {Rigor::Analysis::Runner#run}) is responsible for
        # setting it on the main Ractor before spawning the
        # pool. The substrate stays Ractor-safe by construction.
        @rbs_extended_reporter = RbsExtended::Reporter.new
        @boundary_cross_reporter = DependencySourceInference::BoundaryCrossReporter.new
        @dependency_source_index = DependencySourceInference::Builder.build(configuration.dependencies)

        @services = Plugin::Services.new(
          reflection: Reflection,
          type: Type::Combinator,
          configuration: configuration,
          cache_store: cache_store,
          trust_policy: build_trust_policy
        )
        @plugin_registry = Plugin::Registry.materialize(
          blueprints: plugin_blueprints, services: @services
        )
        @environment = Environment.for_project(
          libraries: configuration.libraries,
          signature_paths: configuration.signature_paths,
          cache_store: cache_store,
          plugin_registry: @plugin_registry,
          dependency_source_index: @dependency_source_index,
          rbs_extended_reporter: @rbs_extended_reporter,
          boundary_cross_reporter: @boundary_cross_reporter,
          bundler_bundle_path: configuration.bundler_bundle_path,
          bundler_auto_detect: configuration.bundler_auto_detect
        )
        @prepare_diagnostics = run_plugin_prepare.freeze
      end

      # Equivalent of {Rigor::Analysis::Runner#analyze_file} +
      # `plugin_emitted_diagnostics` + `explain_diagnostics`.
      # Returns a flat `Array<Diagnostic>` for the file. Severity
      # profile re-stamping is intentionally NOT applied — that
      # is a per-run aggregate concern handled by the caller.
      def analyze(path)
        parse_result = Prism.parse_file(path, version: @configuration.target_ruby)
        return parse_diagnostics(path, parse_result) unless parse_result.errors.empty?

        scope = Scope.empty(environment: @environment, source_path: path)
        index = Inference::ScopeIndexer.index(parse_result.value, default_scope: scope)
        diagnostics = CheckRules.diagnose(
          path: path,
          root: parse_result.value,
          scope_index: index,
          comments: parse_result.comments,
          disabled_rules: @configuration.disabled_rules
        )
        diagnostics += plugin_emitted_diagnostics(path, parse_result.value, scope)
        diagnostics + explain_diagnostics(path, parse_result.value, scope)
      rescue Errno::ENOENT => e
        [analyzer_error(path, e.message)]
      rescue StandardError => e
        [analyzer_error(path, "internal analyzer error: #{e.class}: #{e.message}")]
      end

      # Read-once snapshot of the per-worker reporters so the
      # caller (or the eventual Phase 4b pool aggregator) can
      # merge into a single coordinator-side reporter. Both
      # reporters dedupe at write time, so a post-hoc concat +
      # de-dup at the entry-key level is sound.
      def drain_reporters
        {
          rbs_extended: {
            unresolved_payloads: @rbs_extended_reporter.unresolved_payloads,
            lossy_projections: @rbs_extended_reporter.lossy_projections
          },
          boundary_cross: @boundary_cross_reporter.entries
        }
      end

      private

      # Mirrors {Runner#build_trust_policy}. Workers under Phase
      # 4b will need the same trust derivation, and the
      # configuration is already shareable, so deriving it inside
      # the session keeps the substrate decoupled from the
      # coordinator's helper.
      def build_trust_policy
        trusted_gems = @configuration.plugins.map { |entry| trusted_gem_name(entry) }.uniq
        roots = [Dir.pwd]
        Array(@configuration.signature_paths).each { |sp| roots << File.expand_path(sp) }
        trusted_gems.each do |gem_name|
          path = trusted_gem_root(gem_name)
          roots << path if path
        end
        @configuration.plugins_io_allowed_paths.each { |p| roots << File.expand_path(p) }

        Plugin::TrustPolicy.new(
          trusted_gems: trusted_gems,
          allowed_read_roots: roots,
          network_policy: @configuration.plugins_io_network,
          allowed_url_hosts: @configuration.plugins_io_allowed_url_hosts
        )
      end

      def trusted_gem_name(entry)
        case entry
        when String then entry
        when Hash then entry["gem"] || entry["id"]
        end
      end

      def trusted_gem_root(gem_name)
        return nil if gem_name.nil? || gem_name.empty?

        spec = Gem.loaded_specs[gem_name]
        spec&.full_gem_path # rigor:disable undefined-method
      rescue StandardError
        nil
      end

      def run_plugin_prepare
        return [] if @plugin_registry.empty?

        @plugin_registry.plugins.flat_map do |plugin|
          plugin.prepare(plugin.services)
          []
        rescue StandardError => e
          [plugin_prepare_error_diagnostic(plugin, e)]
        end
      end

      def plugin_prepare_error_diagnostic(plugin, error)
        plugin_id = safe_plugin_id(plugin)
        Diagnostic.new(
          path: ".rigor.yml",
          line: 1,
          column: 1,
          message: "plugin #{plugin_id.inspect} raised during prepare: " \
                   "#{error.class}: #{error.message}",
          severity: :error,
          rule: "runtime-error",
          source_family: :plugin_loader
        )
      end

      def plugin_emitted_diagnostics(path, root, scope)
        return [] if @plugin_registry.empty?

        @plugin_registry.plugins.flat_map do |plugin|
          collect_plugin_diagnostics(plugin, path, root, scope)
        end
      end

      def collect_plugin_diagnostics(plugin, path, root, scope)
        raw = plugin.diagnostics_for_file(path: path, scope: scope, root: root)
        Array(raw).map { |diagnostic| stamp_plugin_diagnostic(diagnostic, plugin.manifest.id) }
      rescue StandardError => e
        [plugin_runtime_error_diagnostic(path, plugin, e)]
      end

      def stamp_plugin_diagnostic(diagnostic, plugin_id)
        Diagnostic.new(
          path: diagnostic.path,
          line: diagnostic.line,
          column: diagnostic.column,
          message: diagnostic.message,
          severity: diagnostic.severity,
          rule: diagnostic.rule,
          source_family: "plugin.#{plugin_id}"
        )
      end

      def plugin_runtime_error_diagnostic(path, plugin, error)
        plugin_id = safe_plugin_id(plugin)
        Diagnostic.new(
          path: path,
          line: 1,
          column: 1,
          message: "plugin #{plugin_id.inspect} raised during diagnostics_for_file: " \
                   "#{error.class}: #{error.message}",
          severity: :error,
          rule: "runtime-error",
          source_family: :plugin_loader
        )
      end

      def safe_plugin_id(plugin)
        plugin.manifest.id
      rescue StandardError
        plugin.class.to_s
      end

      def explain_diagnostics(path, root, scope)
        return [] unless @explain

        result = Inference::CoverageScanner.new(scope: scope).scan(root)
        result.events.map { |event| explain_diagnostic(path, event) }
      end

      def explain_diagnostic(path, event)
        location = event.location
        line = location ? location.start_line : 1
        column = location ? location.start_column + 1 : 1
        Diagnostic.new(
          path: path,
          line: line,
          column: column,
          message: "fail-soft fallback at #{event.node_class}: #{event.inner_type.describe(:short)}",
          severity: :info,
          rule: "fallback"
        )
      end

      def parse_diagnostics(path, parse_result)
        parse_result.errors.map do |error|
          location = error.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: error.message,
            severity: :error
          )
        end
      end

      def analyzer_error(path, message)
        Diagnostic.new(path: path, line: 1, column: 1, message: message, severity: :error)
      end
    end
  end
end
