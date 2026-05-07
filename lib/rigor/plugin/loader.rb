# frozen_string_literal: true

require_relative "registry"
require_relative "load_error"

module Rigor
  module Plugin
    # Resolves the project's `.rigor.yml` `plugins:` entries into
    # instantiated plugin instances, paired with a service container.
    # Internal slice-1 implementation; the public surface is
    # {Loader.load} returning a {Registry}.
    #
    # Steps per entry (in order):
    #
    # 1. Normalise the entry into `{ gem:, id:, config: }`.
    # 2. `require` the gem (failures surface as a {LoadError}).
    # 3. Look up the registered plugin class by id (or by gem
    #    name if the entry omitted an explicit id).
    # 4. Validate the user's config against the manifest's
    #    `config_schema`.
    # 5. Instantiate the plugin and call `init(services)`.
    #
    # Loading is deterministic: configuration order, with plugin
    # id alphabetical as the tie-breaker for entries that resolve
    # to the same gem. Failures do not abort the run; the loader
    # collects them on the {Registry} so the runner can convert
    # each one into a `:plugin_loader` diagnostic.
    class Loader # rubocop:disable Metrics/ClassLength
      attr_reader :services, :requirer

      # @param services [Rigor::Plugin::Services]
      # @param requirer [#call] takes a gem name and returns truthy
      #   on successful require. Defaulted to `Kernel.require` via
      #   a lambda; the spec injects a fake to avoid touching the
      #   real load path.
      def initialize(services:, requirer: ->(name) { require name })
        @services = services
        @requirer = requirer
      end

      def self.load(configuration:, services:, requirer: ->(name) { require name })
        new(services: services, requirer: requirer).load(configuration.plugins)
      end

      # @param entries [Array<String, Hash>] the raw `plugins:`
      #   list from the configuration.
      # @return [Registry]
      def load(entries)
        plugins = []
        load_errors = []
        seen_ids = {}

        Array(entries).each_with_index do |raw, index|
          entry = normalise_entry(raw, index)
        rescue LoadError => e
          load_errors << e
        else
          begin
            plugin = resolve_and_instantiate(entry, seen_ids)
            plugins << plugin if plugin
          rescue LoadError => e
            load_errors << e
          end
        end

        # ADR-9 slice 5 — topological sort by `manifest(consumes:)`
        # so producers run before consumers, plus early
        # `missing-producer` validation. Cycles surface as
        # `dependency-cycle` LoadErrors. When validation fails, the
        # offending plugin(s) drop from the returned plugins list
        # and the LoadError surfaces alongside any earlier failure.
        plugins, sort_errors = topo_sort_plugins(plugins)
        load_errors.concat(sort_errors)

        Registry.new(plugins: plugins, load_errors: load_errors)
      end

      private

      # Accepts:
      #   "rigor-rails"
      #   { "gem" => "rigor-rails", "id" => "rails", "config" => {...} }
      #   { gem: "rigor-rails", id: "rails", config: {...} }
      def normalise_entry(raw, index) # rubocop:disable Metrics/CyclomaticComplexity
        case raw
        when String
          { gem: raw, id: nil, config: {} }
        when Hash
          string_keyed = raw.to_h { |k, v| [k.to_s, v] }
          gem_name = string_keyed["gem"] || string_keyed["id"]
          unless gem_name.is_a?(String) && !gem_name.empty?
            raise LoadError.new(
              "plugin entry ##{index} must declare a non-empty `gem:` (or `id:`), got #{raw.inspect}",
              plugin_ref: raw
            )
          end

          { gem: gem_name, id: string_keyed["id"], config: string_keyed["config"] || {} }
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
        after = Plugin.registered.keys.to_set
        newly_registered = (after - before).to_a

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
        instantiate(plugin_class, entry[:config])
      end

      def require_gem!(entry)
        @requirer.call(entry[:gem])
      rescue ::LoadError => e
        raise LoadError.new(
          "could not load plugin gem #{entry[:gem].inspect}: #{e.message}",
          plugin_ref: entry[:gem],
          cause: e
        )
      end

      def lookup_plugin_class!(entry, newly_registered) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
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
            "plugin gem #{entry[:gem].inspect} registered multiple plugins " \
            "(#{newly_registered.sort.inspect}); disambiguate with an explicit `id:` field",
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

      # ADR-9 slice 5 — topological sort of plugins by their
      # `manifest(consumes:)` declarations. Returns `[sorted_plugins,
      # load_errors]`. Determinism: when no dependency relation
      # forces an order, plugins are visited alphabetically by
      # manifest id. A non-optional consume of a `(plugin_id, name)`
      # whose producer is missing emits a `:missing-producer`
      # LoadError and drops the consumer; cycles emit a
      # `:dependency-cycle` LoadError naming the offending chain.
      def topo_sort_plugins(plugins)
        # If no plugin opts into the cross-plugin API the loader's
        # legacy configuration-order contract is preserved
        # unchanged. Topo sort and missing-producer validation only
        # run when at least one plugin declares `consumes:`.
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

      # Kahn's algorithm with `Configuration#plugins`-order
      # tie-break. Edges go from producer -> consumer (producer
      # must visit first). When two plugins are simultaneously
      # ready, the configuration-order index decides the visit
      # order — preserves the v0.1.0 legacy contract for plugins
      # without dependencies.
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
