# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "../../support/spec_tmpdir"

module Rigor
  module IntegrationSupport
    # Shared helpers for the plugin integration specs under `spec/integration/plugins/` (production plugins)
    # and `spec/integration/examples/` (walkthrough samples). Auto-included for files that match the path
    # pattern (see RSpec.configure block at the bottom of this file). Specs explicitly `include` this module if
    # they live elsewhere.
    #
    # ## Required `let` bindings
    #
    # Every spec that uses these helpers MUST declare:
    #
    #     let(:plugin_class) { Rigor::Plugin::SomePluginClass }
    #
    # The helpers read `plugin_class` via RSpec's `let` / method-resolution surface, so subsequent calls do NOT
    # repeat the class on each invocation. Plugin id is derived from `plugin_class.manifest.id`.
    #
    # ## What each helper does
    #
    # - `run_plugin(source:, ...)` — materialises a tmpdir containing `demo.rb` (and optionally extra
    #   `files:`), builds a `Rigor::Configuration` listing the plugin, runs `Rigor::Analysis::Runner` against
    #   it, and returns the `Rigor::Analysis::Result`. Auto-`unregister!`s the plugin registry before each
    #   invocation so the loader's newly-registered diff sees a fresh state.
    # - `plugin_diagnostics(result)` — filters a result down to diagnostics whose `source_family` matches the
    #   plugin's manifest id (`"plugin.<id>"`).
    # - `build_plugin_requirer` — returns the `requirer` lambda the plugin loader expects. Specs that drive
    #   `Analysis::Runner` themselves (e.g. routes' multi-run cache test) call this directly.
    # - `materialize_files(dir, files)` — convenience for specs that build their tmpdir manually.
    # - `run_plugin_in_dir(dir:, source:, ...)` — lower-level variant that accepts an existing tmpdir, for
    #   specs that need to run multiple analyses against the same project (e.g. cache invalidation tests).
    #
    # Both `run_plugin` and `run_plugin_in_dir` raise via {InternalAnalyzerErrorGuard} before returning if the
    # `Result` carries a diagnostic from either analyzer-crash rescue site — a check rule raising into the
    # `"internal analyzer error"` diagnostic, or a PLUGIN raising out of `#diagnostics_for_file` / `#prepare`
    # into the `:plugin_loader` / `"runtime-error"` diagnostic (which `plugin_diagnostics` below would
    # otherwise silently exclude, since its `source_family` never matches `"plugin.<id>"`). Either one means
    # a rule or plugin crashed instead of running, which an absence assertion would otherwise treat as "the
    # rule declined to fire" (issue #665).
    #
    # ## Why not `before { unregister! }` automation?
    #
    # `run_plugin` calls `Rigor::Plugin.unregister!` at the start of every invocation. Specs may STILL declare
    # `before { Rigor::Plugin.unregister! }` / `after { Rigor::Plugin.unregister! }` for visibility — the
    # belt-and-braces is harmless and surfaces the lifecycle for readers.
    #
    # ## Why `cache_store: :shared` is the default
    #
    # The persistent `Cache::Store` caches the per-run RBS environment, constant table, instance/singleton
    # definitions, and known-class set. With `cache_store: nil` every call paid the full ~250ms cold env build;
    # using one process-wide store warms the cache after the first call so subsequent calls are ~30ms each
    # (≈7× faster). The descriptor's `gems` / `files` / `configs` / `plugins` slots key the entries so
    # different plugins, sigs, and libraries automatically land in separate slots — cross-test contamination is
    # impossible. Tests that need to assert cache behaviour explicitly (e.g. `routes_plugin_spec`'s
    # invalidation surface) pass an explicit `cache_store:` to opt out.
    module PluginHelpers
      class << self
        def shared_cache_store
          @shared_cache_store ||= Rigor::Cache::Store.new(root: shared_cache_root)
        end

        # Process-wide by design, so it has no block to close and no example to hang an `after` hook on;
        # {SpecTmpdir.suite_lifetime} releases it when the suite ends (issue #330).
        def shared_cache_root
          @shared_cache_root ||= SpecTmpdir.suite_lifetime("rigor-plugin-spec-cache-")
        end
      end

      # Sentinel default. Callers can pass `:shared` for the process-wide store, an explicit `Cache::Store`, or
      # `nil` for no caching (the historical default — every call pays the cold ~250ms env build). The
      # process-wide store is opt-in per spec file via `cache_store: :shared` (or via the
      # `default_run_plugin_cache_store` let override) because it is only a net win for spec files with many
      # `run_plugin` calls: cache I/O overhead exceeds the per-call env build savings up to and including ≈17
      # examples per spec file (measured: a 17-example file got ~12 % slower under shared cache). The crossover
      # sits closer to the high end of plugin-spec example counts, so only the heaviest files opt in today —
      # sorbet's 48 examples shrink from 13.1 s to 4.7 s with the shared cache (≈3× faster). Spec files whose
      # plugin's `cache_for(...)` descriptor is incomplete (does not include the project files the producer
      # reads from) MUST avoid the shared cache because stale producer output leaks between examples.
      DEFAULT_CACHE_STORE = :default

      def default_run_plugin_cache_store
        nil
      end

      def run_plugin(source:, plugin_entry: nil, cache_store: DEFAULT_CACHE_STORE,
                     files: {}, paths: nil, signature_paths: nil)
        Rigor::Plugin.unregister!
        Dir.mktmpdir do |dir|
          run_plugin_in_dir(
            dir: dir,
            source: source,
            plugin_entry: plugin_entry,
            cache_store: cache_store,
            files: files,
            paths: paths,
            signature_paths: signature_paths
          )
        end
      end

      class ExpectedPluginNotRegisteredError < StandardError; end

      def run_plugin_in_dir(dir:, source:, plugin_entry: nil, cache_store: DEFAULT_CACHE_STORE,
                            files: {}, paths: nil, signature_paths: nil)
        materialize_files(dir, files)
        File.write(File.join(dir, "demo.rb"), source)
        effective_entry = plugin_entry || default_plugin_entry
        configuration = build_plugin_configuration(
          dir: dir,
          plugin_entry: effective_entry,
          paths: paths,
          signature_paths: signature_paths
        )
        effective_cache = resolve_cache_store(cache_store)
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration,
          cache_store: effective_cache,
          plugin_requirer: build_plugin_requirer
        )

        result = Dir.chdir(dir) do
          runner.run
        end

        assert_expected_plugin_registered!(runner, effective_entry)
        InternalAnalyzerErrorGuard.check!(result, context: "run_plugin_in_dir")
      end

      def assert_expected_plugin_registered!(runner, effective_entry)
        expected_id = plugin_class.manifest.id
        entry_hash = effective_entry.is_a?(Hash) ? effective_entry.to_h { |k, v| [k.to_s, v] } : {}
        return if entry_hash["enabled"] == false || runner.plugin_registry.find(expected_id)

        errors = runner.plugin_registry.load_errors.map(&:message)
        suffix = errors.empty? ? nil : " (load errors: #{errors.join('; ')})"
        raise ExpectedPluginNotRegisteredError,
              "run_plugin_in_dir: expected plugin #{expected_id.inspect} to be registered, " \
              "but loaded plugins were #{runner.plugin_registry.ids.inspect}#{suffix}"
      end

      def resolve_cache_store(cache_store)
        cache_store = default_run_plugin_cache_store if cache_store == DEFAULT_CACHE_STORE
        cache_store == :shared ? PluginHelpers.shared_cache_store : cache_store
      end

      def plugin_diagnostics(result)
        result.diagnostics.select { |d| d.source_family == default_plugin_source_family }
      end

      def build_plugin_requirer
        # Capture plugin_class in a local so the lambda doesn't close over `self` (specs may share a
        # `let`-resolved binding across nested describes; capturing avoids surprising re-evaluation).
        plugin_class_local = plugin_class
        lambda do |_name|
          Rigor::Plugin.register(plugin_class_local)
          true
        end
      end

      def materialize_files(dir, files)
        files.each do |relative_path, contents|
          full = File.join(dir, relative_path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, contents)
        end
      end

      private

      def default_plugin_entry
        "rigor-#{plugin_class.manifest.id}"
      end

      def default_plugin_source_family
        "plugin.#{plugin_class.manifest.id}"
      end

      def build_plugin_configuration(dir:, plugin_entry:, paths:, signature_paths: nil)
        path_list = paths || ["demo.rb"]
        entry = case plugin_entry
                when Hash
                  e = plugin_entry.to_h { |k, v| [k.to_s, v] }
                  e["id"] ||= plugin_class.manifest.id if respond_to?(:plugin_class) && plugin_class
                  e
                else
                  plugin_entry
                end
        merged = Rigor::Configuration::DEFAULTS.merge(
          "paths" => path_list.map { |p| File.join(dir, p) },
          "plugins" => [entry]
        )
        merged = merged.merge("signature_paths" => signature_paths.map { |p| File.join(dir, p) }) if signature_paths
        Rigor::Configuration.new(merged)
      end
    end
  end
end

RSpec.configure do |config|
  config.include Rigor::IntegrationSupport::PluginHelpers, type: :plugin_integration
  config.define_derived_metadata(
    file_path: %r{/spec/integration/(plugins|examples)/.+_plugin_spec\.rb\z}
  ) do |meta|
    meta[:type] = :plugin_integration
  end
end
