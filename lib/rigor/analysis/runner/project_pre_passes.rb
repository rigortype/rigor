# frozen_string_literal: true

require_relative "../../plugin"
require_relative "../../reflection"
require_relative "../../type/combinator"
require_relative "../../inference/scope_indexer"
require_relative "../../inference/synthetic_method_scanner"
require_relative "../../inference/project_patched_scanner"
require_relative "../dependency_source_inference"
require_relative "../project_scan"

module Rigor
  module Analysis
    class Runner
      # Owns every project-wide pre-pass that runs once per run before
      # per-file analysis: plugin load + `#prepare`, the ADR-10
      # dependency-source index, the ADR-16 synthetic-method scanner,
      # the ADR-17 project-patched (`pre_eval:`) scanner, cross-file
      # class discovery, and the ADR-24 def-node + visibility index.
      # Also owns the {ProjectScan} snapshot adopt / build paths the LSP
      # uses.
      #
      # The collaborator produces a frozen {Result} bundle; the {Runner}
      # assigns each slot onto its own ivar surface, preserving the exact
      # assignment order and timing the inline body had. The `pool_mode`
      # predicate is injected (it keys on `@workers` / `@buffer`, owned by
      # the Runner) so this collaborator never calls back into it.
      class ProjectPrePasses
        # Frozen bundle of the project-wide state the pre-passes produce.
        # Mirrors the ivars `run_project_pre_passes` / `adopt_prebuilt`
        # set on the {Runner}, in the same order they were assigned.
        Result = Data.define(
          :plugin_registry,
          :dependency_source_index,
          :cached_plugin_prepare_diagnostics,
          :synthetic_method_index,
          :project_patched_methods,
          :pre_eval_diagnostics_from_scanner,
          :discovered_classes,
          :discovered_def_nodes,
          :discovered_singleton_def_nodes,
          :discovered_def_sources,
          :discovered_superclasses,
          :discovered_includes,
          :discovered_class_sources,
          :discovered_method_visibilities,
          :discovered_methods,
          :data_member_layouts,
          :struct_member_layouts
        )

        # @param configuration [Rigor::Configuration]
        # @param cache_store [Rigor::Cache::Store, nil]
        # @param buffer [BufferBinding, nil]
        # @param plugin_requirer [#call, nil]
        # @param pool_mode [#call] reader returning the pool-mode flag.
        def initialize(configuration:, cache_store:, buffer:, plugin_requirer:, pool_mode:)
          @configuration = configuration
          @cache_store = cache_store
          @buffer = buffer
          @plugin_requirer = plugin_requirer
          @pool_mode_reader = pool_mode
        end

        # Internal: drives every project-wide pre-pass and returns the
        # results bundled in {Result} in the order the downstream `#run`
        # body expects. Extracted so `#prepare_project_scan` and the
        # prebuilt-less `#run` path share one implementation.
        def run(expansion:) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
          plugin_registry = load_plugins
          dependency_source_index = DependencySourceInference::Builder.build(@configuration.dependencies)
          # ADR-18 slice 3 — plugin prepare MUST run before the
          # synthetic-method scanner so cross-plugin facts
          # (`:dry_type_aliases` etc.) are already published when
          # the scanner resolves Tier C `returns_from_arg:`
          # lookups. The diagnostics produced by prepare are
          # captured here so `pre_file_diagnostics` can re-emit
          # them in the existing order without invoking prepare
          # twice. Pool mode still re-runs prepare per worker
          # (workers don't see this early invocation), preserving
          # the existing Phase 4b contract.
          cached_plugin_prepare_diagnostics =
            pool_mode? ? [] : plugin_prepare_diagnostics(plugin_registry)
          # ADR-16 slice 2b — Tier C pre-pass. Built once per run
          # against the resolved file set + the loaded plugin
          # registry's `heredoc_templates` so synthetic methods are
          # visible cross-file when per-file inference dispatches.
          synthetic_method_index = Inference::SyntheticMethodScanner.scan(
            plugin_registry: plugin_registry,
            paths: expansion.fetch(:files),
            environment: nil,
            fact_store: shared_fact_store(plugin_registry),
            buffer: @buffer
          )
          # ADR-17 slice 2 — pre-eval pre-pass. Built once per run
          # from the `pre_eval:` entries that exist on disk
          # (slice-1's `pre-eval.file-not-found` `:error` already
          # surfaced any missing entries; the scanner skips them
          # here). The resulting {ProjectPatchedMethods} registry
          # is consulted by the dispatcher tier between plugins
          # and dependency-source inference so project-side
          # patches resolve cross-file.
          existing_pre_eval = @configuration.pre_eval.select { |path| File.file?(path) }
          pre_eval_outcome = Inference::ProjectPatchedScanner.scan(existing_pre_eval, buffer: @buffer)
          project_patched_methods = pre_eval_outcome.registry
          pre_eval_diagnostics_from_scanner = pre_eval_outcome.diagnostics
          # Cross-file class discovery — walks every project file
          # for `class Foo` / `module Bar` declarations so a
          # `Foo.method_call` receiver in one file resolves a
          # `class Foo` declared in a sibling file. Without this
          # pre-pass each file's `discovered_classes` was per-file
          # only, and lexical lookup fell back to stdlib `::Foo`
          # for any user class shadowing a stdlib name (e.g.
          # `Google::Cloud::Storage::File`). Cost is one extra
          # parse pass over the project; small projects pay
          # tens of ms, larger projects ~1s. Future optimisation
          # can share parses with the existing scanner passes.
          discovered_classes =
            Inference::ScopeIndexer.discovered_classes_for_paths(expansion.fetch(:files), buffer: @buffer)
          # ADR-24 slice 2 — cross-file def-node + class->superclass
          # index so an implicit-self call inside a subclass
          # resolves a superclass `def` declared in a sibling
          # file. One extra parse pass over the project; shares
          # the cost profile of the class-discovery pass above.
          def_index =
            Inference::ScopeIndexer.discovered_def_index_for_paths(expansion.fetch(:files), buffer: @buffer)
          Result.new(
            plugin_registry: plugin_registry,
            dependency_source_index: dependency_source_index,
            cached_plugin_prepare_diagnostics: cached_plugin_prepare_diagnostics,
            synthetic_method_index: synthetic_method_index,
            project_patched_methods: project_patched_methods,
            pre_eval_diagnostics_from_scanner: pre_eval_diagnostics_from_scanner,
            discovered_classes: discovered_classes,
            discovered_def_nodes: def_index.fetch(:def_nodes),
            discovered_singleton_def_nodes: def_index.fetch(:singleton_def_nodes),
            discovered_def_sources: def_index.fetch(:def_sources),
            discovered_superclasses: def_index.fetch(:superclasses),
            discovered_includes: def_index.fetch(:includes),
            discovered_class_sources: def_index.fetch(:class_sources),
            discovered_method_visibilities: def_index.fetch(:method_visibilities),
            discovered_methods: def_index.fetch(:methods),
            data_member_layouts: def_index.fetch(:data_member_layouts),
            struct_member_layouts: def_index.fetch(:struct_member_layouts)
          )
        end

        # Builds the LSP-facing {ProjectScan} snapshot from a fresh
        # pre-pass run. The runner adopts `result` onto its ivars first
        # so the same registry object that ran `#prepare` (and so the
        # populated `services.fact_store`) is the one the snapshot
        # carries.
        def build_project_scan(result)
          ProjectScan.new(
            plugin_registry: result.plugin_registry,
            dependency_source_index: result.dependency_source_index,
            synthetic_method_index: result.synthetic_method_index,
            project_patched_methods: result.project_patched_methods,
            plugin_prepare_diagnostics: result.cached_plugin_prepare_diagnostics.dup.freeze,
            pre_eval_diagnostics: result.pre_eval_diagnostics_from_scanner.dup.freeze
          )
        end

        # Translates a prebuilt {ProjectScan} snapshot supplied to
        # `Runner.new(prebuilt: ...)` into a {Result} the runner adopts
        # the same way it adopts a fresh pre-pass run. The discovery
        # tables are not part of the snapshot (the LSP path seeds an
        # empty project scope), so they stay at their frozen-empty
        # constructor defaults.
        def adopt_prebuilt(scan)
          Result.new(
            plugin_registry: scan.plugin_registry,
            dependency_source_index: scan.dependency_source_index,
            cached_plugin_prepare_diagnostics: scan.plugin_prepare_diagnostics,
            synthetic_method_index: scan.synthetic_method_index,
            project_patched_methods: scan.project_patched_methods,
            pre_eval_diagnostics_from_scanner: scan.pre_eval_diagnostics,
            discovered_classes: nil,
            discovered_def_nodes: nil,
            discovered_singleton_def_nodes: nil,
            discovered_def_sources: nil,
            discovered_superclasses: nil,
            discovered_includes: nil,
            discovered_class_sources: nil,
            discovered_method_visibilities: nil,
            discovered_methods: nil,
            data_member_layouts: nil,
            struct_member_layouts: nil
          )
        end

        # Returns the per-run shared `Plugin::FactStore` instance.
        # All loaded plugins share this store through their
        # respective `Plugin::Services` (the same instance is
        # threaded by `Plugin::Loader.load`). Returns `nil` when
        # no plugins are loaded.
        def shared_fact_store(plugin_registry)
          return nil if plugin_registry.nil? || plugin_registry.empty?

          plugin_registry.plugins.first&.services&.fact_store
        end

        private

        def pool_mode?
          @pool_mode_reader.call
        end

        # Loads project-configured plugins through {Rigor::Plugin::Loader}
        # and returns the resulting {Rigor::Plugin::Registry}. Loader
        # failures are isolated: each surfaces as a `:plugin_loader`
        # diagnostic on the run's `Result` rather than aborting the
        # analysis. Plugins that load successfully but contribute no
        # protocol hooks are inert in slice 1; later v0.1.0 slices
        # wire the contribution merger through this registry.
        def load_plugins
          return Plugin::Registry::EMPTY if @configuration.plugins.empty?

          services = Plugin::Services.new(
            reflection: Reflection,
            type: Type::Combinator,
            configuration: @configuration,
            cache_store: @cache_store,
            trust_policy: build_trust_policy
          )
          if @plugin_requirer
            Plugin::Loader.load(configuration: @configuration, services: services, requirer: @plugin_requirer)
          else
            Plugin::Loader.load(configuration: @configuration, services: services)
          end
        end

        # Builds the {Rigor::Plugin::TrustPolicy} for this run. Trusted
        # gems are the gem-name half of every entry in
        # `Configuration#plugins`. Allowed read roots default to the
        # project root (CWD), the project's signature_paths, and each
        # trusted gem's `Gem::Specification#full_gem_path`, plus any
        # extras the user listed under `plugins_io.allowed_paths`.
        # Slice 2 keeps `network_policy` `:disabled` — the only value
        # the configuration accepts today.
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

        # ADR-9 slice 3 — invokes every loaded plugin's `#prepare`
        # hook once per run, after the loader's `#init` pass and
        # before per-file iteration. Plugins publish facts here
        # for cross-plugin consumption via the shared
        # `services.fact_store`. Failures isolate as
        # `:plugin_loader runtime-error` diagnostics, mirroring the
        # `#diagnostics_for_file` raise envelope in
        # `plugin_runtime_error_diagnostic`.
        #
        # `Plugin::Loader` returns plugins in topological order by
        # `manifest(consumes:)` (ADR-9 slice 5), so producers
        # always run before consumers.
        def plugin_prepare_diagnostics(plugin_registry)
          return [] if plugin_registry.empty?

          plugin_registry.plugins.flat_map { |plugin| invoke_plugin_prepare(plugin) }
        end

        def invoke_plugin_prepare(plugin)
          plugin.prepare(plugin.services)
          []
        rescue StandardError => e
          [plugin_prepare_error_diagnostic(plugin, e)]
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

        def safe_plugin_id(plugin)
          plugin.manifest.id
        rescue StandardError
          plugin.class.to_s
        end
      end
    end
  end
end
