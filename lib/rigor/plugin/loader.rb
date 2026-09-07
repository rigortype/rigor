# frozen_string_literal: true

require_relative "blueprint"
require_relative "registry"
require_relative "load_error"

module Rigor
  module Plugin
    # Resolves the project's `.rigor.yml` `plugins:` entries into instantiated plugin instances, paired with a
    # service container. Internal slice-1 implementation; the public surface is {Loader.load} returning a
    # {Registry}.
    #
    # Steps per entry (in order):
    #
    # 0. Skip the entry entirely when it carries `enabled: false` (the ADR-93 WD2 opt-out).
    # 1. Normalise the entry into `{ gem:, id:, config:, enabled: }`.
    # 2. `require` the gem (failures surface as a {LoadError}).
    # 3. Look up the registered plugin class by id (or by gem name if the entry omitted an explicit id).
    # 4. Validate the user's config against the manifest's `config_schema`.
    # 5. Instantiate the plugin and call `init(services)`.
    #
    # Loading is deterministic: configuration order, with plugin id alphabetical as the tie-breaker for
    # entries that resolve to the same gem. Failures do not abort the run; the loader collects them on the
    # {Registry} so the runner can convert each one into a `:plugin_loader` diagnostic.
    class Loader # rubocop:disable Metrics/ClassLength
      attr_reader :services, :requirer, :feature_resolver

      # #194 slice 1 — resolve the file that satisfied `require <gem>` by scanning `$LOADED_FEATURES` for the
      # entry ending in `/<gem>.rb`, LAST match preferred. Provenance-agnostic: it pins the actual file for a
      # Bundler path gem, an installed gem, and a `-I`-injected checkout alike, and — because the feature is
      # already present from the first load — it still resolves when `require` no-ops on a repeat in-process
      # load (ADR-88 WD4b). Returns nil, never raises, in the degenerate cases: a gem whose entry-file
      # basename differs from the gem name, and a spec's fake requirer that never populated `$LOADED_FEATURES`.
      FEATURE_RESOLVER = lambda do |gem_name|
        suffix = "/#{gem_name}.rb"
        $LOADED_FEATURES.rfind { |feature| feature.end_with?(suffix) }
      end

      # #194 slice 2 (ADR-93 WD5) — the engine's own root, anchored from THIS file's location: the loader
      # lives at `<root>/lib/rigor/plugin/loader.rb`, so three levels up is the engine root. It resolves
      # identically in a git checkout and inside an installed `rigortype` gem, because the gem packages the
      # `plugins/` tree at the same relative path — which is exactly what makes it a trustworthy anchor for
      # the engine's own bundled plugin copies.
      ENGINE_ROOT = File.expand_path("../../..", __dir__)

      # @rbs requirer: untyped --
      #   Takes a gem name OR an absolute file path (#194 slice 2 — a bundled plugin is required by its
      #   {.bundled_plugin_path}) and returns truthy on successful require. Defaulted to `Kernel.require` via a
      #   lambda, which accepts both forms; the spec injects a fake to avoid touching the real load path.
      # @rbs feature_resolver: untyped --
      #   Takes a gem name and returns the absolute path `require` resolved it to (or nil). Defaulted to
      #   {FEATURE_RESOLVER}; the spec injects a fake so it never has to mutate the real `$LOADED_FEATURES` global.
      def initialize(services:, requirer: ->(name) { require name }, feature_resolver: FEATURE_RESOLVER)
        @services = services
        @requirer = requirer
        @feature_resolver = feature_resolver
      end

      def self.load(configuration:, services:, requirer: ->(name) { require name }, feature_resolver: FEATURE_RESOLVER)
        new(services: services, requirer: requirer, feature_resolver: feature_resolver).load(configuration.plugins)
      end

      # #194 slice 2 (ADR-93 WD5) — the absolute path of the engine's OWN bundled copy of a plugin gem
      # (`<ENGINE_ROOT>/plugins/<gem>/lib/<gem>.rb`), or nil when the engine does not bundle it. A bundled
      # plugin is required by this path rather than by gem name, so a stale installed `rigortype` gem can
      # never displace the engine's own versioned copy through RubyGems name resolution — the engine and its
      # bundled plugins are versioned together. Returns nil for a third-party / project-bundle plugin and for
      # a trimmed packaging (the ADR-27 single-binary target that ships no `plugins/` tree), where the caller
      # falls back to today's gem-name require so no install mode regresses. The rule is uniform across the
      # auto-wired `rigor-rbs-inline` default and every user-listed entry, because the skew mechanism is
      # identical for both. Also read by `rigor doctor`'s skew check (#194 slice 3) to decide which loaded
      # plugins the engine bundles.
      def self.bundled_plugin_path(gem_name)
        path = File.join(ENGINE_ROOT, "plugins", gem_name, "lib", "#{gem_name}.rb")
        File.file?(path) ? path : nil
      end

      # The signature half of {.bundled_plugin_path}: the absolute `sig/` directory of the engine's OWN
      # bundled copy of a plugin gem (`<ENGINE_ROOT>/plugins/<gem>/sig`), or nil when the engine does not
      # bundle it, it ships no signatures, or the packaging carries no `plugins/` tree (ADR-27).
      #
      # Unlike its sibling this is NOT a require anchor — nothing loads Ruby from it. It exists so the
      # engine can recognise its own bundled RBS when a project reaches that directory by a route the
      # plugin registry never sees: a `signature_paths:` entry pointing straight at it (issue #672). The
      # anchor is deliberately the same `ENGINE_ROOT`, so a git checkout and an installed `rigortype` gem
      # answer identically and the two halves of a bundled plugin can never resolve to different copies.
      def self.bundled_plugin_sig_path(gem_name)
        path = File.join(ENGINE_ROOT, "plugins", gem_name, "sig")
        File.directory?(path) ? path : nil
      end

      # @rbs entries: Array[String | Hash[untyped, untyped]] -- The raw `plugins:` list from the configuration.
      def load(entries)
        plugins = []
        load_errors = []
        seen_ids = {}
        # #194 slice 1 — `gem name => resolved file path` for every gem the loader successfully required.
        # A frozen plugin instance (e.g. `rigor-rbs-inline` self-freezes per ADR-32) can't carry the path,
        # so it rides on the Registry keyed by gem name; the `rigor plugins` loaded row reads it back.
        @resolved_gem_paths = {}

        Array(entries).each_with_index do |raw, index|
          entry = normalise_entry(raw, index)
        rescue LoadError => e
          load_errors << e
        else
          # ADR-93 WD2 — `enabled: false` opts a listed plugin out entirely: it is neither required nor
          # trusted nor id-checked. This is the project-level opt-out for the auto-wired `rigor-rbs-inline`
          # default (a user re-lists it with `enabled: false`), but it works for any entry.
          next unless entry[:enabled]

          begin
            plugin = resolve_and_instantiate(entry, seen_ids)
            plugins << plugin if plugin
          rescue LoadError => e
            load_errors << e
          end
        end

        # ADR-9 slice 5 — topological sort by `manifest(consumes:)` so producers run before consumers, plus
        # early `missing-producer` validation. Cycles surface as `dependency-cycle` LoadErrors. When
        # validation fails, the offending plugin(s) drop from the returned plugins list and the LoadError
        # surfaces alongside any earlier failure.
        plugins, sort_errors = topo_sort_plugins(plugins)
        load_errors.concat(sort_errors)

        blueprints = plugins.map { |plugin| Blueprint.new(klass_name: plugin.class.name, config: plugin.config) }
        Registry.new(plugins: plugins, blueprints: blueprints, load_errors: load_errors,
                     resolved_gem_paths: @resolved_gem_paths)
      end

      private

      # Accepts:
      #   "rigor-activerecord"
      #   { "gem" => "rigor-activerecord", "id" => "activerecord", "config" => {...} }
      #   { gem: "rigor-activerecord", id: "activerecord", config: {...} }
      #
      # The `id:` form selects one plugin from a gem that registers several — the bare-string form
      # raises for those (see `lookup_plugin_class!`).
      def normalise_entry(raw, index)
        case raw
        when String
          { gem: raw, id: nil, config: {}, enabled: true }
        when Hash
          string_keyed = raw.to_h { |k, v| [k.to_s, v] }
          gem_name = string_keyed["gem"] || string_keyed["id"]
          unless gem_name.is_a?(String) && !gem_name.empty?
            raise LoadError.new(
              "plugin entry ##{index} must declare a non-empty `gem:` (or `id:`), got #{raw.inspect}",
              plugin_ref: raw
            )
          end

          # `enabled:` defaults to true; only the explicit `false` disables (nil / absent stays enabled).
          { gem: gem_name, id: string_keyed["id"], config: string_keyed["config"] || {},
            enabled: string_keyed["enabled"] != false }
        else
          raise LoadError.new(
            "plugin entry ##{index} must be a String or Hash, got #{raw.class}",
            plugin_ref: raw
          )
        end
      end

      def resolve_and_instantiate(entry, seen_ids) # rubocop:disable Metrics/AbcSize
        before = Plugin.registered.keys.to_set
        require_gem!(entry)
        # The require SUCCEEDED — pin the file it resolved to (nil when the resolver can't, never a raise).
        # Recorded before the fallible steps below so a config/init failure can still name the loaded copy.
        @resolved_gem_paths[entry[:gem]] = @feature_resolver.call(entry[:gem])
        after = Plugin.registered.keys.to_set
        newly_registered = (after - before).to_a

        # ADR-88 WD4b — `require` runs a gem's body (and its `Rigor::Plugin.register` calls) at most ONCE per
        # process. A first load captures the gem's ids in `newly_registered` and memoises the gem→ids mapping;
        # a SECOND in-process load (the `--verify-incremental` full-run oracle, the incremental session's
        # subset re-analysis, LSP re-loads) sees `require` no-op and an empty delta, so a bare-string
        # (`id:`-less) entry recovers the gem's ids from the memo instead of raising "did not register any
        # plugin". An explicit `id:` entry never needs this — it resolves by id directly in `lookup_plugin_class!`.
        if newly_registered.any?
          Plugin.record_gem_registration(entry[:gem], newly_registered)
        elsif entry[:id].nil?
          newly_registered = Plugin.ids_for_gem(entry[:gem])
        end

        plugin_class = lookup_plugin_class!(entry, newly_registered)
        manifest = plugin_class.manifest

        if seen_ids.key?(manifest.id)
          raise LoadError.new(
            "plugin id #{manifest.id.inspect} appeared twice in configuration " \
            "(first via #{seen_ids[manifest.id].inspect}, again via #{entry[:gem].inspect})",
            plugin_ref: manifest.id
          )
        end
        seen_ids[manifest.id] = entry[:gem]

        validate_config!(manifest, entry[:config])
        plugin = instantiate(plugin_class, entry[:config])
        validate_signature_paths!(plugin)
        plugin
      rescue LoadError => e
        # #194 slice 1 — annotate a POST-require failure (bad config, a raising `#init`, a missing signature
        # dir, a duplicate id, no/many registrations) with the file the gem loaded from, so the surfaced
        # diagnostic names the exact plugin copy. A require that failed outright never populated the map for
        # this gem, so the lookup is nil and the message is left unchanged.
        e.resolved_path ||= @resolved_gem_paths[entry[:gem]]
        raise
      end

      # ADR-25 — a plugin's manifest-declared `signature_paths:` are resolved (by
      # `Plugin::Base#signature_paths`) against the plugin gem root. A declared directory that does not exist
      # is a load-time failure for that plugin — loud, not silent, because a missing `sig/` means the bundle
      # gem is broken. The raised LoadError is collected like any other load failure and the plugin drops
      # from the registry.
      def validate_signature_paths!(plugin)
        plugin.signature_paths.each do |dir|
          next if File.directory?(dir)

          raise LoadError.new(
            "plugin #{plugin.manifest.id.inspect} declares signature path #{dir.inspect} " \
            "which is not a directory",
            plugin_ref: plugin.manifest.id
          )
        end
      end

      # #194 slice 2 (ADR-93 WD5) — a bundled plugin is required by its engine-anchored absolute path; every
      # other gem keeps today's bare-name require. The injectable `requirer` seam therefore widens from gem
      # names to name-or-absolute-path (both are valid arguments to `Kernel.require`). The slice-1
      # `feature_resolver` is unaffected: an absolute-path require's `$LOADED_FEATURES` entry still ends in
      # `/<gem>.rb`, the suffix {FEATURE_RESOLVER} matches.
      def require_gem!(entry)
        @requirer.call(self.class.bundled_plugin_path(entry[:gem]) || entry[:gem])
      rescue ::LoadError => e
        raise LoadError.new(
          "could not load plugin gem #{entry[:gem].inspect}: #{e.message}",
          plugin_ref: entry[:gem],
          cause: e
        )
      end

      def lookup_plugin_class!(entry, newly_registered)
        if entry[:id]
          plugin_class = Plugin.registered_for(entry[:id])
          unless plugin_class
            raise LoadError.new(
              "plugin id #{entry[:id].inspect} (gem #{entry[:gem].inspect}) " \
              "did not register itself with Rigor::Plugin.register",
              plugin_ref: entry[:id]
            )
          end

          return plugin_class
        end

        case newly_registered.size
        when 0
          raise LoadError.new(
            "plugin gem #{entry[:gem].inspect} did not register any plugin via Rigor::Plugin.register",
            plugin_ref: entry[:gem]
          )
        when 1
          Plugin.registered_for(newly_registered.first)
        else
          raise LoadError.new(
            "plugin gem #{entry[:gem].inspect} bundles #{newly_registered.size} plugins " \
            "(#{newly_registered.sort.inspect}) and cannot be activated as a single `plugins:` entry — " \
            "it is a convenience meta-gem. List the individual plugin gems you want in `plugins:` " \
            "(e.g. `rigor-#{newly_registered.min}`), or select one with an explicit `id:` field.",
            plugin_ref: entry[:gem]
          )
        end
      end

      def validate_config!(manifest, config)
        errors = manifest.validate_config(config)
        return if errors.empty?

        raise LoadError.new(
          "plugin #{manifest.id.inspect} config invalid: #{errors.join('; ')}",
          plugin_ref: manifest.id
        )
      end

      def instantiate(plugin_class, config)
        plugin = plugin_class.new(services: @services, config: config)
        plugin.init(@services)
        plugin
      rescue StandardError => e
        manifest_id = safe_manifest_id(plugin_class)
        raise LoadError.new(
          "plugin #{manifest_id.inspect} raised during init: #{e.class}: #{e.message}",
          plugin_ref: manifest_id,
          cause: e
        )
      end

      def safe_manifest_id(plugin_class)
        plugin_class.manifest.id
      rescue StandardError
        plugin_class.to_s
      end

      # ADR-9 slice 5 — topological sort of plugins by their `manifest(consumes:)` declarations. Returns
      # `[sorted_plugins, load_errors]`. Determinism: when no dependency relation forces an order, plugins
      # are visited alphabetically by manifest id. A non-optional consume of a `(plugin_id, name)` whose
      # producer is missing emits a `:missing-producer` LoadError and drops the consumer; cycles emit a
      # `:dependency-cycle` LoadError naming the offending chain.
      def topo_sort_plugins(plugins)
        # If no plugin opts into the cross-plugin API the loader's legacy configuration-order contract is
        # preserved unchanged. Topo sort and missing-producer validation only run when at least one plugin
        # declares `consumes:`.
        return [plugins, []] unless plugins.any? { |p| p.manifest.consumes.any? }

        index = plugins.to_h { |plugin| [plugin.manifest.id, plugin] }
        errors = validate_missing_producers(plugins, index)
        sortable = plugins.reject { |p| errors.any? { |e| e.plugin_ref == p.manifest.id } }
        config_order = plugins.each_with_index.to_h { |plugin, i| [plugin.manifest.id, i] }

        sort_in_topo_order(sortable, index, errors, config_order)
      end

      def validate_missing_producers(plugins, index)
        errors = []
        plugins.each do |plugin|
          plugin.manifest.consumes.each do |consume|
            next if consume.optional
            next if index.key?(consume.plugin_id) && producer_provides?(index[consume.plugin_id], consume.name)

            errors << LoadError.new(
              "plugin #{plugin.manifest.id.inspect} consumes " \
              "#{consume.plugin_id.inspect}/#{consume.name} but no loaded plugin " \
              "with that id declares `produces: [#{consume.name.inspect}]`",
              plugin_ref: plugin.manifest.id,
              reason: :"missing-producer"
            )
          end
        end
        errors
      end

      def producer_provides?(producer, name)
        producer.manifest.produces.include?(name)
      end

      # Kahn's algorithm with `Configuration#plugins`-order tie-break. Edges go from producer -> consumer
      # (producer must visit first). When two plugins are simultaneously ready, the configuration-order index
      # decides the visit order — preserves the v0.1.0 legacy contract for plugins without dependencies.
      def sort_in_topo_order(plugins, index, errors, config_order)
        in_degree, forward = build_consumes_graph(plugins, index, errors)
        ordered, cycle_errors = kahn_walk(plugins, in_degree, forward, config_order)
        [ordered, errors + cycle_errors]
      end

      def build_consumes_graph(plugins, index, errors)
        in_degree = Hash.new(0)
        forward = Hash.new { |h, k| h[k] = [] }
        plugins.each do |consumer|
          consumer.manifest.consumes.each do |consume|
            next unless index.key?(consume.plugin_id)
            next if errors.any? { |e| e.plugin_ref == consume.plugin_id }

            forward[consume.plugin_id] << consumer.manifest.id
            in_degree[consumer.manifest.id] += 1
          end
        end
        [in_degree, forward]
      end

      def kahn_walk(plugins, in_degree, forward, config_order)
        order = ->(plugin) { config_order.fetch(plugin.manifest.id, Float::INFINITY) }
        ready = plugins.select { |p| in_degree[p.manifest.id].zero? }.sort_by(&order)
        result = kahn_collect(plugins, in_degree, forward, ready, order)

        return [result, []] if result.size == plugins.size

        cycled = plugins - result
        [result, [dependency_cycle_error(cycled)]]
      end

      def kahn_collect(plugins, in_degree, forward, ready, order)
        result = []
        until ready.empty?
          plugin = ready.shift
          result << plugin
          forward[plugin.manifest.id].each do |consumer_id|
            in_degree[consumer_id] -= 1
            ready << plugins.find { |p| p.manifest.id == consumer_id } if in_degree[consumer_id].zero?
          end
          ready.sort_by!(&order)
        end
        result
      end

      def dependency_cycle_error(cycled)
        ids = cycled.map { |p| p.manifest.id }.sort
        LoadError.new(
          "plugin dependency cycle through `manifest(consumes:)`: #{ids.inspect}",
          plugin_ref: ids.first,
          reason: :"dependency-cycle"
        )
      end
    end
  end
end
