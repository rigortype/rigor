# frozen_string_literal: true

module Rigor
  module Plugin
    # ADR-28 declaration: "every instance/singleton method named
    # `method_name`, defined in a source file matching `path_glob`,
    # is implicitly required to satisfy the declared parameter +
    # return-type protocol."
    #
    # Authored on a plugin manifest:
    #
    #   manifest(
    #     id: "web",
    #     version: "0.1.0",
    #     protocol_contracts: [
    #       Rigor::Plugin::ProtocolContract.new(
    #         path_glob: "lib/controller/**/*.rb",
    #         method_name: :get,
    #         param_types: [{ index: 0, type_name: "Rack::Request" }],
    #         return_type_name: "Rack::Response"
    #       )
    #     ]
    #   )
    #
    # The contract drives two distinct engine behaviours (ADR-28
    # § "provide-and-check"):
    #
    # - **provide** — when the inference engine binds the parameter
    #   list of a matching `def`, {Rigor::Inference::MethodParameterBinder}
    #   substitutes the declared `param_types` for the usual
    #   `Dynamic[Top]` fallback, so the method body is analysed as
    #   if the parameter carried its protocol type.
    # - **check** — the contributing plugin's `#diagnostics_for_file`
    #   hook confirms the method exists and its inferred return type
    #   conforms to `return_type_name`.
    #
    # ## Fields
    #
    # - `path_glob` — `File.fnmatch` glob (String) selecting the
    #   source files the contract applies to, relative to the
    #   analysed project root (e.g. `"lib/controller/**/*.rb"`).
    # - `method_name` — Symbol; the instance (or singleton) method
    #   the contract constrains.
    # - `singleton` — Boolean; `true` constrains `def self.<name>`,
    #   `false` (default) constrains instance methods.
    # - `param_types` — Array of `ParamType` (positional index →
    #   fully-qualified type name). The type names resolve against
    #   the analysed project's environment lazily, at consumption
    #   time, so the contract value object stays independent of
    #   environment construction order.
    # - `return_type_name` — fully-qualified type name (String) the
    #   method's inferred return type must conform to.
    # - `severity` — Symbol diagnostic severity for contract
    #   violations (`:error` default).
    #
    # ## Ractor-shareability
    #
    # Every field is frozen at construction (ADR-15 Phase 1); the
    # nested `ParamType` is a frozen `Data`. `Ractor.shareable?`
    # returns true after `#initialize`, so the contract survives
    # `Plugin::Registry.materialize` into a worker Ractor.
    class ProtocolContract
      VALID_SEVERITIES = %i[error warning info].freeze

      # One positional-parameter provision: the zero-based index of
      # the parameter and the fully-qualified name of the type it
      # carries under the protocol.
      ParamType = Data.define(:index, :type_name)

      attr_reader :path_glob, :method_name, :singleton, :param_types, :return_type_name, :severity

      def initialize(path_glob:, method_name:, return_type_name: nil, param_types: [], singleton: false,
                     severity: :error)
        validate_path_glob!(path_glob)
        validate_method_name!(method_name)
        validate_return_type_name!(return_type_name)
        validate_severity!(severity)

        @path_glob = path_glob.dup.freeze
        @method_name = method_name.to_sym
        @singleton = singleton ? true : false
        @param_types = coerce_param_types(param_types)
        @return_type_name = return_type_name.nil? ? nil : return_type_name.dup.freeze
        @severity = severity.to_sym
        freeze
      end

      # Returns a copy with `path_glob` replaced. Plugins use this to
      # honour a per-project config override of the convention path
      # without rebuilding the whole contract by hand.
      def with_path_glob(glob)
        ProtocolContract.new(
          path_glob: glob,
          method_name: method_name,
          return_type_name: return_type_name,
          param_types: param_types.map { |pt| { index: pt.index, type_name: pt.type_name } },
          singleton: singleton,
          severity: severity
        )
      end

      def to_h
        {
          "path_glob" => path_glob,
          "method_name" => method_name.to_s,
          "singleton" => singleton,
          "param_types" => param_types.map { |pt| { "index" => pt.index, "type_name" => pt.type_name } },
          "return_type_name" => return_type_name,
          "severity" => severity.to_s
        }
      end

      def ==(other)
        other.is_a?(ProtocolContract) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      private

      def validate_path_glob!(value)
        return if value.is_a?(String) && !value.empty?

        raise ArgumentError,
              "Plugin::ProtocolContract#path_glob must be a non-empty String, got #{value.inspect}"
      end

      def validate_method_name!(value)
        return if value.is_a?(Symbol) || (value.is_a?(String) && !value.empty?)

        raise ArgumentError,
              "Plugin::ProtocolContract#method_name must be a Symbol/non-empty String, got #{value.inspect}"
      end

      def validate_return_type_name!(value)
        return if value.nil?
        return if value.is_a?(String) && !value.empty?

        raise ArgumentError,
              "Plugin::ProtocolContract#return_type_name must be a non-empty String or nil, got #{value.inspect}"
      end

      def validate_severity!(value)
        return if VALID_SEVERITIES.include?(value.to_sym)

        raise ArgumentError,
              "Plugin::ProtocolContract#severity must be one of #{VALID_SEVERITIES.inspect}, got #{value.inspect}"
      rescue NoMethodError
        raise ArgumentError,
              "Plugin::ProtocolContract#severity must be one of #{VALID_SEVERITIES.inspect}, got #{value.inspect}"
      end

      def coerce_param_types(param_types)
        unless param_types.is_a?(Array)
          raise ArgumentError,
                "Plugin::ProtocolContract#param_types must be an Array, got #{param_types.inspect}"
        end

        param_types.map { |entry| coerce_param_type(entry) }.freeze
      end

      def coerce_param_type(entry)
        return entry if entry.is_a?(ParamType)

        unless entry.is_a?(Hash)
          raise ArgumentError,
                "Plugin::ProtocolContract param_types entry must be a Hash or ParamType, got #{entry.inspect}"
        end

        index = entry[:index] || entry["index"]
        type_name = entry[:type_name] || entry["type_name"]
        unless index.is_a?(Integer) && index >= 0 && type_name.is_a?(String) && !type_name.empty?
          raise ArgumentError,
                "Plugin::ProtocolContract param_types entry needs an Integer index >= 0 and a " \
                "non-empty String type_name, got #{entry.inspect}"
        end

        ParamType.new(index: index, type_name: type_name.dup.freeze)
      end
    end
  end
end
