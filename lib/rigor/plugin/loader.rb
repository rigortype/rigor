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
    end
  end
end
