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
require_relative "../effects/collector"
require_relative "../inference/scope_indexer"
require_relative "../inference/method_dispatcher/file_folding"
require_relative "check_rules"
require_relative "dependency_recorder"
require_relative "dependency_source_inference"
require_relative "diagnostic"
require_relative "erb_template_detector"

module Rigor
  module Analysis
    # ADR-15 Phase 4a — per-worker analysis substrate. [ADR-15](../../../docs/adr/15-ractor-concurrency.md) §
    # Phase 4 carves the Ractor-isolated worker pool into sub-phases; 4a/4b/4c all landed, but the Ractor
    # pool (4b) is blocked by Ruby Bug #22075 (UAF) — the active pool backend is fork (ADR-15 Amendment).
    # This class exists so the per-worker ownership boundary is testable independently of any pool
    # coordinator.
    #
    # The constructor takes only `Ractor.shareable?` inputs:
    #
    # - `configuration` — Phase 2a ({Rigor::Configuration} is `Ractor.shareable?`).
    # - `cache_store` — the fork backend passes the parent runner's pre-built Store (`cache_store:
    #   @cache_store` in PoolCoordinator); workers share it rather than building their own at `cache_root`.
    # - `plugin_blueprints` — Phase 3a (`Array<Plugin::Blueprint>` is `Ractor.shareable?`).
    # - `explain` — Boolean.
    # - `synthetic_method_index` / `project_patched_methods` / `project_scope_seed` — optional (default `nil`
    #   / `{}`). NOT `Ractor.shareable?` (the seed tables carry Prism def nodes), so the Ractor pool path
    #   leaves them unset; the fork backend (ADR-15 Amendment), which builds the session pre-fork on the
    #   parent, threads the runner's project-scan results through so per-file inference matches the
    #   sequential path exactly. `project_scope_seed` is `Runner#project_scope_seed_tables` — the cross-file
    #   discovery tables `seed_project_scope` applies to every per-file scope on the sequential path;
    #   without it a worker cannot resolve calls to methods defined in OTHER project files and emits
    #   `call.undefined-method` false positives the sequential path does not.
    #
    # Internally the session OWNS (and never shares):
    #
    # - {Rigor::Plugin::Services} bound to the per-worker Store.
    # - {Rigor::Plugin::Registry} materialised from the blueprints via {Rigor::Plugin::Registry.materialize};
    #   each plugin instance, with its mutable per-run accumulators (`@reachable_absurd_nodes`, `*_index`,
    #   …) lives entirely inside this session.
    # - {Rigor::RbsExtended::Reporter} + {Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter}
    #   (Mutex-bearing; intentionally per-worker — the runner merges entries post-pool via
    #   {#drain_reporters}).
    # - {Rigor::Environment} threaded with the per-worker reporters so reporter writes from inference /
    #   dispatcher accumulate into the worker's own state.
    #
    # Plugin `prepare` runs ONCE at construction time so each worker is "warm" by the time `#analyze` is
    # first called. Any raise from `prepare` is captured into {#prepare_diagnostics} so the runner can
    # surface them alongside the per-file diagnostic stream.
    #
    # Equivalence contract (proven by spec): given identical `(configuration, cache_store,
    # plugin_blueprints)`, the multiset of diagnostics from `paths.flat_map { |p| session.analyze(p) }` plus
    # {#prepare_diagnostics} plus reporter drains MUST equal the corresponding subset of
    # {Rigor::Analysis::Runner#run}'s output (modulo severity-profile re-stamping, which the session leaves
    # to the caller because it is a per-run aggregate concern).
    class WorkerSession # rubocop:disable Metrics/ClassLength
      attr_reader :configuration, :cache_store, :services, :plugin_registry,
                  :dependency_source_index, :environment,
                  :rbs_extended_reporter, :boundary_cross_reporter,
                  :prepare_diagnostics

      # @param configuration [Rigor::Configuration]
      # @param cache_store [Rigor::Cache::Store, nil] persistent cache the session exposes to plugin-side
      #   producers and the RBS loader. Pass `nil` to disable caching.
      # @param plugin_blueprints [Array<Rigor::Plugin::Blueprint>] replay descriptors. Empty array yields a
      #   session with no plugin contributions.
      # @param explain [Boolean] when true, `#analyze` additionally emits one `:info` `fallback` diagnostic
      #   per directly-unrecognised node, mirroring {Rigor::Analysis::Runner#explain_diagnostics}.
      def initialize(configuration:, cache_store: nil, # rubocop:disable Metrics/MethodLength,Metrics/ParameterLists
                     plugin_blueprints: [], explain: false, buffer: nil,
                     synthetic_method_index: nil, project_patched_methods: nil,
                     project_scope_seed: {}, source_files: [], record_dependencies: false)
        @configuration = configuration
        @cache_store = cache_store
        @explain = explain
        @buffer = buffer
        @synthetic_method_index = synthetic_method_index
        @project_patched_methods = project_patched_methods
        @project_scope_seed = project_scope_seed || {}
        # ADR-46 — when set (the `--incremental` pool path), each `#analyze` is wrapped in a
        # `DependencyRecorder.record_for` so the worker captures the file's cross-file reads, and the records
        # are marshalled back to the coordinator ({#drain_dependencies}). Mirrors `Runner#analyze_file`. A
        # normal `--workers N` run leaves it false and pays nothing (the recorder's disabled fast path).
        @record_dependencies = record_dependencies
        @file_dependencies = {}
        # ADR-103 WD13 — effect collection, derived from the configuration exactly as `Runner` derives it,
        # so a worker and the parent agree without a flag to keep in sync. Records marshal back through
        # {#drain_effects}.
        @record_effects = configuration.effects_enabled?
        @file_effects = {}
        # ADR-32 WD4 — full project file list (frozen Array<String>) for env-build-time invocation of any
        # loaded plugin's `source_rbs_synthesizer` callable.
        @source_files = source_files

        # NOTE: `Inference::MethodDispatcher::FileFolding.fold_platform_specific_paths` is process-global
        # state. Writing it from a non-main Ractor would raise `Ractor::IsolationError`, so the session does
        # NOT touch it — the CALLER (typically {Rigor::Analysis::Runner#run}) is responsible for setting it
        # on the main Ractor before spawning the pool. The substrate stays Ractor-safe by construction.
        @rbs_extended_reporter = RbsExtended::Reporter.new
        @boundary_cross_reporter = DependencySourceInference::BoundaryCrossReporter.new
        @source_rbs_synthesis_reporter = Plugin::SourceRbsSynthesisReporter.new
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
          source_rbs_synthesis_reporter: @source_rbs_synthesis_reporter,
          bundler_bundle_path: configuration.bundler_bundle_path,
          bundler_auto_detect: configuration.bundler_auto_detect,
          bundler_lockfile: configuration.bundler_lockfile,
          rbs_collection_lockfile: configuration.rbs_collection_lockfile,
          rbs_collection_auto_detect: configuration.rbs_collection_auto_detect,
          synthetic_method_index: @synthetic_method_index,
          project_patched_methods: @project_patched_methods,
          source_files: @source_files
        )
        @prepare_diagnostics = run_plugin_prepare.freeze
      end

      # Equivalent of {Rigor::Analysis::Runner#analyze_file} + `plugin_emitted_diagnostics` +
      # `explain_diagnostics`. Returns a flat `Array<Diagnostic>` for the file. Severity profile re-stamping
      # is intentionally NOT applied — that is a per-run aggregate concern handled by the caller. When
      # `record_dependencies:` was set, wraps the analysis in a {DependencyRecorder} window (ADR-46) so the
      # worker captures the file's cross-file reads for {#drain_dependencies}; the recorder's own disabled
      # fast path makes the unwrapped case free.
      def analyze(path)
        return analyze_with_effects(path) unless @record_dependencies

        diagnostics = nil
        record = DependencyRecorder.record_for(path) { diagnostics = analyze_with_effects(path) }
        @file_dependencies[path] = record
        diagnostics
      end

      # ADR-103 WD13 — the worker-side mirror of `Runner#analyze_with_effects`.
      def analyze_with_effects(path)
        return analyze_body(path) unless @record_effects

        diagnostics = nil
        collection = Effects::Collector.collect_for(path) { diagnostics = analyze_body(path) }
        @file_effects[path] = collection
        diagnostics
      end
      private :analyze_with_effects

      def analyze_body(path)
        parse_result = parse_source(path)
        unless parse_result.errors.empty?
          return [] if ErbTemplateDetector.template?(parse_result)

          return parse_diagnostics(path, parse_result)
        end

        Effects::Collector.record_root(parse_result.value)
        scope = seed_project_scope(Scope.empty(environment: @environment, source_path: path))
        index = Inference::ScopeIndexer.index(parse_result.value, default_scope: scope)
        # ADR-53 B4 — built-in collectors + plugin node rules share one walk.
        node_collectors = CheckRules.build_node_collectors(path, index)
        node_results = node_rule_results_by_plugin(path, parse_result.value, scope, node_collectors, index)
        diagnostics = CheckRules.diagnose(
          path: path,
          root: parse_result.value,
          scope_index: index,
          comments: parse_result.comments,
          disabled_rules: @configuration.disabled_rules,
          node_collectors: node_collectors
        )
        diagnostics += plugin_emitted_diagnostics(path, parse_result.value, scope, node_results)
        diagnostics + explain_diagnostics(path, parse_result.value, scope)
      rescue Errno::ENOENT => e
        [analyzer_error(path, e.message)]
      rescue StandardError => e
        [analyzer_error(path, "internal analyzer error: #{e.class}: #{e.message}")]
      end
      private :analyze_body

      # Read-once snapshot of the per-worker reporters so the caller (or the eventual Phase 4b pool
      # aggregator) can merge into a single coordinator-side reporter. Both reporters dedupe at write time,
      # so a post-hoc concat + de-dup at the entry-key level is sound.
      def drain_reporters
        {
          rbs_extended: {
            unresolved_payloads: @rbs_extended_reporter.unresolved_payloads,
            lossy_projections: @rbs_extended_reporter.lossy_projections
          },
          boundary_cross: @boundary_cross_reporter.entries,
          source_rbs_synthesis: @source_rbs_synthesis_reporter.entries
        }
      end

      # ADR-46 — the per-file {DependencyRecorder::Record}s captured by this session's `#analyze` calls (empty
      # unless `record_dependencies:` was set). Marshal-clean (Data of frozen Sets / String Hashes), so the
      # fork pool ships them back to the coordinator, which folds them into the runner's `file_dependencies`
      # exactly as the sequential recording path would.
      def drain_dependencies
        @file_dependencies
      end

      # ADR-103 WD12 — the per-file {Effects::FileCollection}s this session collected (empty unless the
      # configuration carries an `effects:` block). Marshal-clean by construction — frozen Hashes of
      # Strings, `LabelSet`s of frozen Arrays, and `Data` edges — so the fork pool ships them back to the
      # coordinator, which folds them into the runner's collection exactly as the sequential path would.
      def drain_effects
        @file_effects
      end

      private

      # Mirrors {Runner#seed_project_scope}: applies the cross-file pre-pass discovery tables the
      # constructor received (fork backend only — see the class comment) to a fresh per-file scope, so
      # worker-side inference resolves project-internal cross-file calls exactly like the sequential path.
      def seed_project_scope(scope)
        return scope if @project_scope_seed.empty?

        scope.with_discovery(scope.discovery.with(**@project_scope_seed))
      end

      # See {Runner#parse_source}. Same contract: if `@buffer` binds `path` to a physical file, read the
      # physical bytes but stamp the parse buffer's `filepath:` as the LOGICAL path so downstream
      # diagnostics carry the logical path.
      def parse_source(path)
        physical = @buffer ? @buffer.resolve(path) : path
        return Prism.parse_file(physical, version: @configuration.target_ruby) if physical == path

        Prism.parse(File.read(physical), filepath: path, version: @configuration.target_ruby)
      end

      # Mirrors {Runner#build_trust_policy}. Deriving trust inside the session keeps the substrate decoupled
      # from the coordinator; configuration is already Ractor-shareable.
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

      def plugin_emitted_diagnostics(path, root, scope, node_results)
        return [] if @plugin_registry.empty?

        @plugin_registry.plugins.flat_map do |plugin|
          collect_plugin_diagnostics(plugin, path, root, scope, node_results[plugin])
        end
      end

      # ADR-52 WD4 + ADR-53 B4 — single engine-owned walk per file drives both the plugin node rules
      # (bucketed per plugin in registry order, plugin-major emission) and the built-in node collectors
      # (`node_collectors`, populated in place). Runs even with no node-rule plugins so the collectors still
      # get driven (converged path).
      def node_rule_results_by_plugin(path, root, scope, node_collectors, scope_index)
        walk = @plugin_registry.node_rule_walk
        driver = node_collectors && CheckRules.node_collector_driver(node_collectors)
        return {}.compare_by_identity if walk.empty? && driver.nil?

        results = walk.diagnostics_for_file(
          path: path, scope: scope, root: root, collector_driver: driver
        )
        if ENV["RIGOR_SHADOW_RULE_WALK"]
          CheckRules.shadow_verify_converged_collectors(path, root, scope_index, node_collectors)
        end
        results.each_with_object({}.compare_by_identity) do |result, by_plugin|
          by_plugin[result.plugin] = result
        end
      end

      def collect_plugin_diagnostics(plugin, path, root, scope, node_result)
        raw = Array(plugin.diagnostics_for_file(path: path, scope: scope, root: root))
        # A node-rule context/rule raise isolates the whole plugin's node-rule contribution, matching the
        # old combined per-plugin rescue (which discarded `diagnostics_for_file` output too).
        raise node_result.error if node_result&.error

        raw += node_result.diagnostics if node_result
        raw.map { |diagnostic| stamp_plugin_diagnostic(diagnostic, plugin.manifest.id) }
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
