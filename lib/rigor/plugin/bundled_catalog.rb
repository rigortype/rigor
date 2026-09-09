# frozen_string_literal: true

# The plugin entry point rather than {Loader} directly: {Registry} closes over constants the package only
# defines in `plugin.rb`'s order, so requiring a leaf of the package first leaves it half-built.
require_relative "../plugin"
require_relative "loader"

module Rigor
  module Plugin
    # ADR-96 WD1/WD2 — the gem-to-plugin index behind the plugin-gap advisory: for every plugin the engine
    # bundles, the gems its manifest declares in `target_gems:`.
    #
    # The index is read off the manifests, never listed here. ADR-96's finding was that the same knowledge
    # sat in four hand-maintained copies (`rigor doctor`, `rigor skill describe`, the project-init prose
    # table, `plugins/README.md`) and none of them was the plugin; a fifth copy in this file would reproduce
    # exactly the drift the field exists to end.
    #
    # Building it requires each bundled plugin's entry file. That loads plugin *classes* — it never runs
    # plugin analysis, which is ADR-96 Criterion 2's line: gem presence is evidence for advice, not for
    # execution. The gem-to-id registrations the requires produce are recorded through
    # {Rigor::Plugin.record_gem_registration}, so a {Loader} running afterwards in the same process still
    # resolves a bare-string `plugins:` entry whose `require` now no-ops (ADR-88 WD4b).
    module BundledCatalog
      # One bundled plugin: the gem name a `plugins:` entry spells, and the gems it models.
      Entry = Data.define(:gem_name, :plugin_id, :target_gems)

      BUNDLED_PLUGINS_ROOT = File.join(Loader::ENGINE_ROOT, "plugins")

      @entries = nil
      @mutex = Mutex.new

      class << self
        # Every bundled plugin that declares at least one target gem, sorted by gem name. Memoised: the
        # requires are process-wide and idempotent, and both callers ask once per command.
        def entries
          @mutex.synchronize { @entries ||= build_entries }
        end

        # The bundled plugins modelling `gem_name`, as `Gemfile.lock` spells it.
        def for_gem(gem_name)
          name = gem_name.to_s
          entries.select { |entry| entry.target_gems.include?(name) }
        end

        # Drops the memo. For specs that stub the engine root only.
        def reset!
          @mutex.synchronize { @entries = nil }
        end

        private

        def build_entries
          require_bundled_plugins
          Plugin.registered.filter_map do |id, plugin_class|
            next unless FirstParty.bundled?(id)

            manifest = plugin_class.manifest
            next if manifest.target_gems.empty?

            Entry.new(gem_name: "#{FirstParty::GEM_PREFIX}#{id}", plugin_id: id,
                      target_gems: manifest.target_gems)
          end.sort_by(&:gem_name).freeze
        end

        # A plugin gem that fails to load is skipped rather than fatal: the catalogue exists to *advise*, and
        # a broken bundled copy is already reported by `rigor doctor`'s plugin checks for the plugins the
        # project actually enabled.
        def require_bundled_plugins
          return unless File.directory?(BUNDLED_PLUGINS_ROOT)

          add_bundled_lib_dirs
          Dir.children(BUNDLED_PLUGINS_ROOT).sort.each do |gem_name|
            path = Loader.bundled_plugin_path(gem_name)
            next if path.nil?

            require_and_record(gem_name, path)
          end
        end

        # A bundled plugin's entry file requires its own tree by bare feature name (`require
        # "rigor/plugin/activestorage"`), which resolves only with that plugin's `lib` on the load path — the
        # loader gets it from the bundle, and this catalogue has to arrange it itself. Prepending the engine's
        # own copies matches ADR-93 WD5's anti-skew rule, where the bundled copy always wins.
        def add_bundled_lib_dirs
          Dir.children(BUNDLED_PLUGINS_ROOT).sort.each do |gem_name|
            dir = File.join(BUNDLED_PLUGINS_ROOT, gem_name, "lib")
            $LOAD_PATH.unshift(dir) if File.directory?(dir) && !$LOAD_PATH.include?(dir)
          end
        end

        def require_and_record(gem_name, path)
          before = Plugin.registered.keys
          require path
          newly_registered = Plugin.registered.keys - before
          Plugin.record_gem_registration(gem_name, newly_registered) unless newly_registered.empty?
        rescue ::LoadError, StandardError
          nil
        end
      end
    end
  end
end
