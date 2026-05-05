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

      attr_reader :id, :version, :description, :protocols, :config_schema

      def initialize(id:, version:, description: nil, protocols: [], config_schema: {})
        validate_id!(id)
        validate_version!(version)
        validate_protocols!(protocols)
        validate_config_schema!(config_schema)

        @id = id.dup.freeze
        @version = version.dup.freeze
        @description = description.nil? ? nil : description.to_s.dup.freeze
        @protocols = protocols.map(&:to_sym).freeze
        @config_schema = config_schema.to_h { |k, v| [k.to_s.dup.freeze, v.to_sym] }.freeze

        freeze
      end

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
          "config_schema" => config_schema.to_h { |k, v| [k, v.to_s] }
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
    end
  end
end
