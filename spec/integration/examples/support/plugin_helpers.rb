# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Rigor
  module IntegrationSupport
    # Shared helpers for the plugin integration specs under
    # `spec/integration/examples/`. Auto-included for files that
    # match the path pattern (see RSpec.configure block at the
    # bottom of this file). Specs explicitly `include` this
    # module if they live elsewhere.
    #
    # ## Required `let` bindings
    #
    # Every spec that uses these helpers MUST declare:
    #
    #     let(:plugin_class) { Rigor::Plugin::SomePluginClass }
    #
    # The helpers read `plugin_class` via RSpec's `let` /
    # method-resolution surface, so subsequent calls do NOT
    # repeat the class on each invocation. Plugin id is derived
    # from `plugin_class.manifest.id`.
    #
    # ## What each helper does
    #
    # - `run_plugin(source:, ...)` — materialises a tmpdir
    #   containing `demo.rb` (and optionally extra `files:`),
    #   builds a `Rigor::Configuration` listing the plugin,
    #   runs `Rigor::Analysis::Runner` against it, and returns
    #   the `Rigor::Analysis::Result`. Auto-`unregister!`s the
    #   plugin registry before each invocation so the loader's
    #   newly-registered diff sees a fresh state.
    # - `plugin_diagnostics(result)` — filters a result down to
    #   diagnostics whose `source_family` matches the plugin's
    #   manifest id (`"plugin.<id>"`).
    # - `build_plugin_requirer` — returns the `requirer` lambda
    #   the plugin loader expects. Specs that drive
    #   `Analysis::Runner` themselves (e.g. routes' multi-run
    #   cache test) call this directly.
    # - `materialize_files(dir, files)` — convenience for specs
    #   that build their tmpdir manually.
    # - `run_plugin_in_dir(dir:, source:, ...)` — lower-level
    #   variant that accepts an existing tmpdir, for specs that
    #   need to run multiple analyses against the same project
    #   (e.g. cache invalidation tests).
    #
    # ## Why not `before { unregister! }` automation?
    #
    # `run_plugin` calls `Rigor::Plugin.unregister!` at the
    # start of every invocation. Specs may STILL declare
    # `before { Rigor::Plugin.unregister! }` /
    # `after { Rigor::Plugin.unregister! }` for visibility — the
    # belt-and-braces is harmless and surfaces the lifecycle
    # for readers.
    module PluginHelpers
      def run_plugin(source:, plugin_entry: nil, cache_store: nil, files: {}, paths: nil)
        Rigor::Plugin.unregister!
        Dir.mktmpdir do |dir|
          run_plugin_in_dir(
            dir: dir,
            source: source,
            plugin_entry: plugin_entry,
            cache_store: cache_store,
            files: files,
            paths: paths
          )
        end
      end

      def run_plugin_in_dir(dir:, source:, plugin_entry: nil, cache_store: nil, files: {}, paths: nil) # rubocop:disable Metrics/ParameterLists
        materialize_files(dir, files)
        File.write(File.join(dir, "demo.rb"), source)
        configuration = build_plugin_configuration(
          dir: dir,
          plugin_entry: plugin_entry || default_plugin_entry,
          paths: paths
        )
        Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration,
            cache_store: cache_store,
            plugin_requirer: build_plugin_requirer
          ).run
        end
      end

      def plugin_diagnostics(result)
        result.diagnostics.select { |d| d.source_family == default_plugin_source_family }
      end

      def build_plugin_requirer
        # Capture plugin_class in a local so the lambda doesn't
        # close over `self` (specs may share a `let`-resolved
        # binding across nested describes; capturing avoids
        # surprising re-evaluation).
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

      def build_plugin_configuration(dir:, plugin_entry:, paths:)
        path_list = paths || ["demo.rb"]
        Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => path_list.map { |p| File.join(dir, p) },
            "plugins" => [plugin_entry]
          )
        )
      end
    end
  end
end

RSpec.configure do |config|
  config.include Rigor::IntegrationSupport::PluginHelpers, type: :plugin_integration
  config.define_derived_metadata(
    file_path: %r{/spec/integration/examples/.+_plugin_spec\.rb\z}
  ) do |meta|
    meta[:type] = :plugin_integration
  end
end
