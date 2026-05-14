# frozen_string_literal: true

module Rigor
  module Plugin
    # Value object describing one plugin's identity and metadata.
    # Constructed once per plugin class through {Rigor::Plugin::Base.manifest};
    # consumed by {Rigor::Plugin::Loader} when matching project
    # configuration entries to registered plugins and by
    # {Rigor::Cache::Descriptor::PluginEntry} when deriving cache keys.
    #
    # The fields are pinned by ADR-2 § "Registration, Configuration,
    # and Caching"; the v0.1.0 plugin contract surface treats this
    # struct as the public manifest shape.
    class Manifest
      # Same regex {Rigor::Cache::Store::VALID_PRODUCER_ID} uses,
      # so plugin ids round-trip through cache producer ids and
      # `plugin.<id>.<rule>` diagnostic identifiers without escape.
      VALID_ID = /\A[a-z][a-z0-9._-]*\z/

      # The first-implementation `config_schema` accepts these value
      # kinds. Slice 1 only checks key presence and shallow value
      # kind; richer schemas (nested maps, enums) land later when
      # the v0.1.0 protocol slices need them.
      VALID_VALUE_KINDS = %i[string boolean integer array hash any].freeze

      # ADR-9 slice 4 — declared cross-plugin fact dependencies.
      # `produces:` lists the names this plugin publishes through
      # its `#prepare(services)` hook. `consumes:` lists the
      # `(plugin_id, name)` pairs this plugin reads from
      # `services.fact_store`. The loader uses both for
      # topological sort + missing-producer detection (slice 5);
      # slice 4 carries the declarations on the manifest but the
      # loader does not yet enforce them.
      class Consumption < Data.define(:plugin_id, :name, :optional)
        def initialize(plugin_id:, name:, optional: false)
          super(plugin_id: plugin_id.to_s, name: name.to_sym, optional: optional ? true : false)
        end
      end

      attr_reader :id, :version, :description, :protocols, :config_schema, :produces, :consumes,
                  :owns_receivers, :type_node_resolvers

      def initialize( # rubocop:disable Metrics/ParameterLists
        id:, version:,
        description: nil, protocols: [], config_schema: {},
        produces: [], consumes: [], owns_receivers: [], type_node_resolvers: []
      )
        validate_id!(id)
        validate_version!(version)
        validate_protocols!(protocols)
        validate_config_schema!(config_schema)
        validate_produces!(produces)
        validate_owns_receivers!(owns_receivers)
        validate_type_node_resolvers!(type_node_resolvers)

        assign_fields(id, version, description, protocols, config_schema, produces, consumes, owns_receivers,
                      type_node_resolvers)
        freeze
      end

      private

      # rubocop:disable Metrics/ParameterLists
      def assign_fields(id, version, description, protocols, config_schema, produces, consumes, owns_receivers,
                        type_node_resolvers)
        @id = id.dup.freeze
        @version = version.dup.freeze
        @description = description.nil? ? nil : description.to_s.dup.freeze
        @protocols = protocols.map(&:to_sym).freeze
        @config_schema = config_schema.to_h { |k, v| [k.to_s.dup.freeze, v.to_sym] }.freeze
        @produces = produces.map(&:to_sym).freeze
        @consumes = coerce_consumes(consumes)
        @owns_receivers = owns_receivers.map { |c| c.to_s.dup.freeze }.freeze
        @type_node_resolvers = type_node_resolvers.dup.freeze
      end
      # rubocop:enable Metrics/ParameterLists

      public

      # Validates the user-supplied plugin config block against this
      # manifest's `config_schema`. Returns an array of human-readable
      # error strings (empty when the config is valid). Slice 1 checks
      # only unknown keys and shallow value kind; nested schemas come
      # with later slices.
      def validate_config(config)
        return ["plugin config must be a Hash, got #{config.class}"] unless config.is_a?(Hash)

        errors = []
        config.each do |key, value|
          key_s = key.to_s
          unless config_schema.key?(key_s)
            errors << "unknown config key #{key_s.inspect} for plugin #{id.inspect}"
            next
          end

          kind = config_schema.fetch(key_s)
          errors << "config key #{key_s.inspect} expected #{kind}, got #{value.class}" unless value_matches?(value,
                                                                                                             kind)
        end
        errors
      end

      def to_h
        {
          "id" => id,
          "version" => version,
          "description" => description,
          "protocols" => protocols.map(&:to_s),
          "config_schema" => config_schema.to_h { |k, v| [k, v.to_s] },
          "produces" => produces.map(&:to_s),
          "consumes" => consumes.map { |c| consumption_hash(c) },
          "owns_receivers" => owns_receivers,
          "type_node_resolvers" => type_node_resolvers.map { |r| r.class.name }
        }
      end

      def ==(other)
        other.is_a?(Manifest) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      private

      def validate_id!(id)
        return if id.is_a?(String) && id.match?(VALID_ID)

        raise ArgumentError,
              "plugin manifest id must match #{VALID_ID.inspect}, got #{id.inspect}"
      end

      def validate_version!(version)
        return if version.is_a?(String) && !version.empty?

        raise ArgumentError, "plugin manifest version must be a non-empty String, got #{version.inspect}"
      end

      def validate_protocols!(protocols)
        return if protocols.is_a?(Array) && protocols.all? { |p| p.is_a?(Symbol) || p.is_a?(String) }

        raise ArgumentError, "plugin manifest protocols must be an Array of Symbol/String, got #{protocols.inspect}"
      end

      def validate_config_schema!(schema)
        unless schema.is_a?(Hash)
          raise ArgumentError,
                "plugin manifest config_schema must be a Hash, got #{schema.inspect}"
        end

        schema.each_value do |kind|
          next if VALID_VALUE_KINDS.include?(kind.to_sym)

          raise ArgumentError,
                "plugin manifest config_schema value kind must be one of " \
                "#{VALID_VALUE_KINDS.inspect}, got #{kind.inspect}"
        end
      end

      def value_matches?(value, kind)
        case kind
        when :string then value.is_a?(String)
        when :boolean then [true, false].include?(value)
        when :integer then value.is_a?(Integer)
        when :array then value.is_a?(Array)
        when :hash then value.is_a?(Hash)
        when :any then true
        else false
        end
      end

      def validate_produces!(produces)
        return if produces.is_a?(Array) && produces.all? { |p| p.is_a?(Symbol) || p.is_a?(String) }

        raise ArgumentError, "plugin manifest produces must be an Array of Symbol/String, got #{produces.inspect}"
      end

      # ADR-10 5a — `owns_receivers:` declares the class names
      # this plugin claims sole ownership of. The dispatcher's
      # dependency-source-inference tier consults this list
      # before consulting its own catalog: receivers owned by a
      # registered plugin (directly or via subclass) decline,
      # so plugin contributions stay authoritative for those
      # types.
      def validate_owns_receivers!(owns_receivers)
        return if owns_receivers.is_a?(Array) && owns_receivers.all? { |c| c.is_a?(String) && !c.empty? }

        raise ArgumentError,
              "plugin manifest owns_receivers must be an Array of non-empty String, " \
              "got #{owns_receivers.inspect}"
      end

      # ADR-13 slice 2 — `type_node_resolvers:` declares the
      # plugin-supplied `TypeNodeResolver` instances the parser
      # consults (in slice 3) when an RBS::Extended payload's
      # named- or generic-type head misses the built-in registry.
      # Slice 2 carries the declarations on the manifest and the
      # registry exposes them in registration order; the parser
      # integration that actually drives the chain lands in
      # slice 3.
      def validate_type_node_resolvers!(resolvers)
        return if resolvers.is_a?(Array) && resolvers.all?(TypeNodeResolver)

        raise ArgumentError,
              "plugin manifest type_node_resolvers must be an Array of " \
              "Rigor::Plugin::TypeNodeResolver instances, got #{resolvers.inspect}"
      end

      def coerce_consumes(consumes)
        unless consumes.is_a?(Array)
          raise ArgumentError, "plugin manifest consumes must be an Array, got #{consumes.inspect}"
        end

        consumes.map { |entry| coerce_consumption(entry) }.freeze
      end

      def coerce_consumption(entry)
        case entry
        when Consumption then entry
        when Hash then build_consumption_from_hash(entry)
        else raise ArgumentError,
                   "plugin manifest consumes entry must be a Hash or Consumption, got #{entry.inspect}"
        end
      end

      def consumption_hash(consumption)
        { "plugin_id" => consumption.plugin_id, "name" => consumption.name.to_s, "optional" => consumption.optional }
      end

      def build_consumption_from_hash(entry)
        plugin_id = entry[:plugin_id] || entry["plugin_id"]
        name = entry[:name] || entry["name"]
        optional = entry.key?(:optional) ? entry[:optional] : entry["optional"]
        if plugin_id.nil? || name.nil?
          raise ArgumentError,
                "plugin manifest consumes entry missing plugin_id/name: #{entry.inspect}"
        end

        Consumption.new(plugin_id: plugin_id, name: name, optional: optional || false)
      end
    end
  end
end
