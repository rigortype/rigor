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
      @load_failures = {}
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

        # The bundled plugin gems whose entry file did not load this process, as `gem name => message`.
        # Empty on a healthy process; a non-empty entry is why a bundled plugin is missing from {entries}.
        def load_failures
          entries
          @mutex.synchronize { @load_failures.dup.freeze }
        end

        # Drops the memo. For specs that stub the engine root only.
        #
        # {load_failures} deliberately survives: `require` is idempotent, so a rebuild after a reset no
        # longer reaches the file that raised and would report a clean process while the entry is still
        # missing.
        def reset!
          @mutex.synchronize { @entries = nil }
        end

        private

        # Bundledness is decided from the paths this module itself resolved and required, never by asking
        # {FirstParty}: that predicate memoises a `File.file?` answer for the whole process, so one spec
        # stubbing the engine root fixes every later answer in the suite — and the catalogue would then
        # silently drop the plugins the advisory exists to name.
        def build_entries
          bundled = require_bundled_plugins
          loaded_plugin_manifests.filter_map do |manifest|
            gem_name = bundled[manifest.id]
            next if gem_name.nil?
            next if manifest.target_gems.empty?

            Entry.new(gem_name: gem_name, plugin_id: manifest.id, target_gems: manifest.target_gems)
          end.sort_by(&:gem_name).freeze
        end

        # The manifests of every plugin class the process has loaded, one per id. Read off the classes
        # rather than {Rigor::Plugin.registered}: `require` is idempotent, so a plugin required earlier and
        # then dropped by `Rigor::Plugin.unregister!` (every spec does this) is absent from the registry
        # while still loaded, and an index built from the registry at that moment silently lacks it — the
        # advisory then reads the project's own enabled plugin as a gap and fails `rigor doctor`.
        #
        # A plugin class whose source file sits under the bundled `plugins/` tree wins its id outright. The
        # suite defines throwaway `Class.new(Rigor::Plugin::Base)` plugins that reuse a bundled id (a
        # `stub_const`-ed fake `activerecord`, for one), and those carry no `target_gems:`; picking one of
        # them for the id erased the real plugin from the index in whatever `ObjectSpace` order that
        # process happened to have. An anonymous class is still consulted, but only for an id no bundled
        # class claims.
        def loaded_plugin_manifests
          bundled = {}
          other = {}
          ObjectSpace.each_object(Class) do |klass|
            next unless klass < Plugin::Base

            manifest = manifest_of(klass)
            next if manifest.nil?

            (bundled_source?(klass) ? bundled : other)[manifest.id] ||= manifest
          end
          other.merge(bundled).values
        end

        def manifest_of(klass)
          klass.manifest
        rescue ArgumentError
          nil
        end

        # Whether `klass` was defined by a file in the engine's own `plugins/` tree. An anonymous class
        # answers false, and so does one whose constant a spec has since removed — which is exactly the
        # shadowing case, since `stub_const` restores the name to nil at the end of the example.
        def bundled_source?(klass)
          name = klass.name
          return false if name.nil?

          location = Object.const_source_location(name)
          return false if location.nil? || location.first.nil?

          location.first.start_with?("#{BUNDLED_PLUGINS_ROOT}#{File::SEPARATOR}")
        rescue NameError
          false
        end

        # @return the gems whose entry file this call resolved, as `plugin id => gem name`.
        def require_bundled_plugins
          return {} unless File.directory?(BUNDLED_PLUGINS_ROOT)

          add_bundled_lib_dirs
          Dir.children(BUNDLED_PLUGINS_ROOT).sort.each_with_object({}) do |gem_name, resolved|
            path = Loader.bundled_plugin_path(gem_name)
            next if path.nil?

            resolved[gem_name.delete_prefix(FirstParty::GEM_PREFIX)] = gem_name
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

        # A plugin gem that fails to load is skipped rather than fatal: the catalogue exists to *advise*, and
        # a broken bundled copy is already reported by `rigor doctor`'s plugin checks for the plugins the
        # project actually enabled. The failure is recorded in {load_failures} so a missing entry stays
        # diagnosable instead of silently narrowing the index.
        def require_and_record(gem_name, path)
          before = Plugin.registered.keys
          require path
          newly_registered = Plugin.registered.keys - before
          Plugin.record_gem_registration(gem_name, newly_registered) unless newly_registered.empty?
        rescue ::LoadError, StandardError => e
          @load_failures[gem_name] = "#{e.class}: #{e.message}"
          nil
        end
      end
    end
  end
end
