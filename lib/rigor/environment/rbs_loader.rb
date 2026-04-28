# frozen_string_literal: true

require "rbs"

require_relative "../type"

module Rigor
  class Environment
    # Loads RBS class declarations and method definitions from disk and
    # exposes them to the inference engine in a small, stable surface.
    #
    # Slice 4 phase 1 only enables the RBS core signatures shipped with
    # the `rbs` gem (`Object`, `Integer`, `String`, `Array`, ...). Stdlib
    # and gem signatures are out of scope and will be opt-in later by
    # accepting an explicit RBS::EnvironmentLoader through the
    # constructor.
    #
    # The default instance is shared across the process: building the
    # core RBS environment costs hundreds of milliseconds and the data
    # is read-only. The shared instance is frozen, but holds a mutable
    # state hash for lazy memoization of the heavy `RBS::Environment`
    # and `RBS::DefinitionBuilder` -- the user-visible API stays purely
    # functional.
    #
    # See docs/internal-spec/inference-engine.md for the binding contract.
    class RbsLoader
      class << self
        def default
          @default ||= new.freeze
        end

        # Used by tests to discard the cached default loader; production
        # code MUST NOT call this. The shared loader holds a several-MB
        # RBS::Environment, so dropping it during a normal run wastes the
        # cost of rebuilding it.
        def reset_default!
          @default = nil
        end
      end

      def initialize
        @state = { env: nil, builder: nil }
        @instance_definition_cache = {}
        @class_known_cache = {}
      end

      # Returns true when an RBS class or module declaration with the given
      # name is loaded. Accepts unprefixed or top-level-prefixed names
      # ("Integer" or "::Integer"). Memoized per-name (positive and
      # negative results both cache).
      def class_known?(name)
        key = name.to_s
        return @class_known_cache[key] if @class_known_cache.key?(key)

        @class_known_cache[key] = compute_class_known(name)
      end

      # @return [RBS::Definition, nil] the resolved instance definition
      #   for `class_name`, or nil when the class is unknown or its
      #   definition cannot be built (RBS may raise on broken hierarchies;
      #   we fail-soft and return nil so the caller can fall back).
      def instance_definition(class_name)
        key = class_name.to_s
        return @instance_definition_cache[key] if @instance_definition_cache.key?(key)

        @instance_definition_cache[key] = build_instance_definition(class_name)
      end

      # @return [RBS::Definition::Method, nil]
      def instance_method(class_name:, method_name:)
        definition = instance_definition(class_name)
        return nil unless definition

        definition.methods[method_name.to_sym]
      end

      private

      def env
        @state[:env] ||= build_env
      end

      def builder
        @state[:builder] ||= RBS::DefinitionBuilder.new(env: env)
      end

      def build_env
        loader = RBS::EnvironmentLoader.new
        RBS::Environment.from_loader(loader).resolve_type_names
      end

      def build_instance_definition(class_name)
        rbs_name = parse_type_name(class_name)
        return nil unless rbs_name
        return nil unless env.class_decls.key?(rbs_name)

        builder.build_instance(rbs_name)
      rescue StandardError
        nil
      end

      def parse_type_name(name)
        s = name.to_s
        return nil if s.empty?

        s = "::#{s}" unless s.start_with?("::")
        RBS::TypeName.parse(s)
      rescue StandardError
        nil
      end

      def compute_class_known(name)
        rbs_name = parse_type_name(name)
        return false unless rbs_name

        # `RBS::Environment#class_decls` after `resolve_type_names`
        # holds entries for both classes AND modules; the gem unifies
        # them under one map post-resolution. Aliases live in their
        # own table.
        env.class_decls.key?(rbs_name) || env.class_alias_decls.key?(rbs_name)
      rescue StandardError
        false
      end
    end
  end
end
