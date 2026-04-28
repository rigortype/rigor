# frozen_string_literal: true

require "rbs"

require_relative "../type"

module Rigor
  class Environment
    # Loads RBS class declarations and method definitions from disk and
    # exposes them to the inference engine in a small, stable surface.
    #
    # Slice 4 phase 1 only enabled the RBS *core* signatures shipped with
    # the `rbs` gem (`Object`, `Integer`, `String`, `Array`, ...). Phase
    # 2a adds opt-in stdlib library loading (`pathname`, `json`,
    # `tempfile`, ...) and arbitrary-directory signature loading
    # (typically the project's local `sig/` tree). Both are off by
    # default on `RbsLoader.default` so the core-only fast path stays
    # cheap; project-aware loading is opted into through
    # {Environment.for_project} or by constructing a custom loader.
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

      attr_reader :libraries, :signature_paths

      # @param libraries [Array<String, Symbol>] stdlib library names to
      #   load on top of core (e.g., `["pathname", "json"]`). Empty by
      #   default. Each entry MUST correspond to a directory under the
      #   `rbs` gem's `stdlib/` tree; unknown names are silently dropped
      #   on environment build (the underlying `RBS::EnvironmentLoader`
      #   raises and we fail-soft).
      # @param signature_paths [Array<String, Pathname>] additional
      #   directories of `.rbs` files to load (typically the project's
      #   `sig/` tree). Non-existent or non-directory paths are filtered
      #   out at build time so the loader stays robust to fixtures and
      #   bare repositories.
      def initialize(libraries: [], signature_paths: [])
        @libraries = libraries.map(&:to_s).freeze
        @signature_paths = signature_paths.map { |p| Pathname(p) }.freeze
        @state = { env: nil, builder: nil }
        @instance_definition_cache = {}
        @singleton_definition_cache = {}
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

      # @return [RBS::Definition, nil] the resolved singleton (class
      #   object) definition for `class_name`. The methods on this
      #   definition are the *class methods* of `class_name`, including
      #   those inherited from `Class` and `Module` for class types.
      #   Returns nil for unknown names and on RBS build errors (fail-soft).
      def singleton_definition(class_name)
        key = class_name.to_s
        return @singleton_definition_cache[key] if @singleton_definition_cache.key?(key)

        @singleton_definition_cache[key] = build_singleton_definition(class_name)
      end

      # @return [RBS::Definition::Method, nil] the class method on
      #   `class_name`. For example, `singleton_method(class_name:
      #   "Integer", method_name: :sqrt)` returns the definition for
      #   `Integer.sqrt`, while `singleton_method(class_name: "Foo",
      #   method_name: :new)` returns Class#new for any class type.
      def singleton_method(class_name:, method_name:)
        definition = singleton_definition(class_name)
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
        rbs_loader = RBS::EnvironmentLoader.new
        @libraries.each do |library|
          # Phase 2a deliberately fails-soft on unknown stdlib libraries
          # so a stale `.rigor.yml` (or future config plumbing) does not
          # take down the whole analyzer. Phase 2b will surface this
          # through diagnostics once the configuration layer can name
          # the offending source. The unknown-library check happens at
          # `from_loader` time, not at `add` time, so we have to gate
          # ahead of `add`.
          next unless rbs_loader.has_library?(library: library, version: nil)

          rbs_loader.add(library: library, version: nil)
        end
        @signature_paths.each do |path|
          rbs_loader.add(path: path) if path.directory?
        end
        RBS::Environment.from_loader(rbs_loader).resolve_type_names
      end

      def build_instance_definition(class_name)
        rbs_name = parse_type_name(class_name)
        return nil unless rbs_name
        return nil unless env.class_decls.key?(rbs_name)

        builder.build_instance(rbs_name)
      rescue StandardError
        nil
      end

      def build_singleton_definition(class_name)
        rbs_name = parse_type_name(class_name)
        return nil unless rbs_name
        return nil unless env.class_decls.key?(rbs_name)

        builder.build_singleton(rbs_name)
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
