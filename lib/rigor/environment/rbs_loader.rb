# frozen_string_literal: true

require "rbs"

require_relative "../type"
require_relative "../inference/rbs_type_translator"
require_relative "rbs_hierarchy"

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
    # rubocop:disable Metrics/ClassLength
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

        # Builds an `RBS::Environment` from explicit `libraries` and
        # `signature_paths`. Stateless surface so the v0.0.9
        # {Cache::RbsEnvironment} producer can build an env on cache
        # miss without holding a loader instance, and the
        # instance-side {#build_env} delegates here so the
        # implementation stays single-rooted.
        def build_env_for(libraries:, signature_paths:)
          rbs_loader = RBS::EnvironmentLoader.new
          libraries.each do |library|
            next unless rbs_loader.has_library?(library: library, version: nil)

            rbs_loader.add(library: library, version: nil)
          end
          signature_paths.each do |path|
            path = Pathname(path) unless path.is_a?(Pathname)
            rbs_loader.add(path: path) if path.directory?
          end
          RBS::Environment.from_loader(rbs_loader).resolve_type_names
        end
      end

      attr_reader :libraries, :signature_paths, :cache_store

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
      # @param cache_store [Rigor::Cache::Store, nil] the persistent
      #   cache the loader consults for translated constant lookups
      #   (and, in later v0.0.9 slices, other Marshal-clean
      #   reflection artefacts). Pass `nil` (the default) to skip
      #   the cache entirely; the runner threads its own Store
      #   through here when caching is enabled.
      def initialize(libraries: [], signature_paths: [], cache_store: nil)
        @libraries = libraries.map(&:to_s).freeze
        @signature_paths = signature_paths.map { |p| Pathname(p) }.freeze
        @cache_store = cache_store
        @state = { env: nil, builder: nil }
        @instance_definition_cache = {}
        @singleton_definition_cache = {}
        @class_known_cache = {}
        @hierarchy = RbsHierarchy.new(self)
      end

      # Returns true when an RBS class or module declaration with the given
      # name is loaded. Accepts unprefixed or top-level-prefixed names
      # ("Integer" or "::Integer"). Memoized per-name (positive and
      # negative results both cache).
      #
      # When `cache_store` is set, the loader fetches the entire set of
      # known class / module / alias names once (per process) through
      # {Cache::RbsKnownClassNames.fetch} and answers `class_known?`
      # from the in-memory Set. Cold runs pay a single env walk and
      # persist the result; warm runs (and a separate loader sharing
      # the same Store) skip the env walk entirely.
      def class_known?(name)
        key = name.to_s
        return @class_known_cache[key] if @class_known_cache.key?(key)

        @class_known_cache[key] = if cache_store
                                    cached_class_known(name)
                                  else
                                    compute_class_known(name)
                                  end
      end

      # Yields every known class / module / alias name (top-level
      # prefixed) currently loaded into the environment. The cache
      # producer that materialises the known-name set uses this so
      # it never recurses back through {#class_known?}.
      def each_known_class_name
        return enum_for(:each_known_class_name) unless block_given?

        env.class_decls.each_key { |rbs_name| yield rbs_name.to_s }
        env.class_alias_decls.each_key { |rbs_name| yield rbs_name.to_s }
      rescue ::RBS::BaseError
        # fail-soft: a broken RBS environment yields no names.
        # Analyzer-internal errors (NameError, NoMethodError,
        # LoadError) are NOT swallowed — those are bugs and
        # must surface so they don't hide silently the way the
        # v0.0.9 cache `Cache::Descriptor` regression did.
      end

      # @return [RBS::Definition, nil] the resolved instance definition
      #   for `class_name`, or nil when the class is unknown or its
      #   definition cannot be built (RBS may raise on broken hierarchies;
      #   we fail-soft and return nil so the caller can fall back).
      #
      # When `cache_store` is set, the loader fetches the per-class
      # definition through {Cache::RbsInstanceDefinitions.fetch} so
      # subsequent runs (and other loaders sharing the same Store)
      # skip the `RBS::DefinitionBuilder.build_instance` step.
      # In-memory `@instance_definition_cache` keeps the per-process
      # short-circuit on top.
      def instance_definition(class_name)
        key = class_name.to_s
        return @instance_definition_cache[key] if @instance_definition_cache.key?(key)

        @instance_definition_cache[key] = if cache_store
                                            cached_instance_definition(class_name)
                                          else
                                            build_instance_definition(class_name)
                                          end
      end

      # Public uncached accessor used by the cache producer
      # ({Rigor::Cache::RbsInstanceDefinitions}). Avoids the
      # `private_method_called` round-trip a `loader.send(...)`
      # callsite would require.
      def uncached_instance_definition(class_name)
        build_instance_definition(class_name)
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
      #
      # When `cache_store` is set, the loader fetches the per-class
      # singleton definition through
      # {Cache::RbsSingletonDefinitions.fetch}; the same caching
      # discipline as {#instance_definition}.
      def singleton_definition(class_name)
        key = class_name.to_s
        return @singleton_definition_cache[key] if @singleton_definition_cache.key?(key)

        @singleton_definition_cache[key] = if cache_store
                                             cached_singleton_definition(class_name)
                                           else
                                             build_singleton_definition(class_name)
                                           end
      end

      # Public uncached accessor used by the cache producer.
      def uncached_singleton_definition(class_name)
        build_singleton_definition(class_name)
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

      # Slice 4 phase 2d. Returns the class's declared type-parameter
      # names as Symbols (e.g., `[:Elem]` for `Array`, `[:K, :V]` for
      # `Hash`). Used by the dispatcher to build the substitution map
      # from receiver `type_args` into the method's return type. The
      # instance definition is the canonical source because singleton
      # methods (e.g., `Array.new`) parameterize over the same `Elem`
      # as instance methods.
      #
      # Returns an empty array for non-generic classes and for unknown
      # names (the loader stays fail-soft). NOTE: in the `rbs` gem,
      # `RBS::Definition#type_params` returns `Array<Symbol>` directly,
      # not the AST `TypeParam` object (those live on the AST level).
      #
      # When `cache_store` is set, the loader fetches the entire
      # type-parameter-name table once (per process) through
      # {Cache::RbsClassTypeParamNames.fetch} and answers point
      # lookups from it. Cold runs build the table once and persist
      # it; warm runs (and a separate loader sharing the same Store)
      # skip the env walk entirely.
      def class_type_param_names(class_name)
        if cache_store
          key = class_name.to_s.delete_prefix("::")
          return type_param_names_table.fetch(key, []).dup
        end

        definition = instance_definition(class_name)
        return [] unless definition

        definition.type_params.dup
      end

      def class_ordering(lhs, rhs)
        @hierarchy.class_ordering(lhs, rhs)
      end

      # @return [Array<String>] every RBS-declared constant name
      #   (top-level prefixed, e.g., `"::Math::PI"`) currently loaded
      #   into the environment. Used by the cache producer that
      #   materialises the constant-type table; ordinary callers
      #   should keep using {#constant_type} for point lookups.
      def constant_names
        env.constant_decls.keys.map(&:to_s)
      rescue ::RBS::BaseError
        []
      end

      # Yields `(name, entry)` for every RBS constant declaration
      # currently loaded into the environment. The cache producer
      # uses this to materialise the constant-type table without
      # going back through {#constant_type} (which would recurse
      # back into the cache when `cache_store` is set).
      def each_constant_decl
        return enum_for(:each_constant_decl) unless block_given?

        env.constant_decls.each do |rbs_name, entry|
          yield rbs_name.to_s, entry
        end
      rescue ::RBS::BaseError
        # fail-soft: a broken RBS environment yields no entries.
      end

      # Slice A constant-value lookup. Returns the translated
      # `Rigor::Type` for a non-class constant declaration
      # (`BUCKETS: Array[Symbol]`, `DEFAULT_PATH: String`, ...) or
      # `nil` when no constant entry exists for `name` in the
      # loaded RBS environment. Callers MUST treat the return
      # value as authoritative when present and as "unknown" when
      # nil; the loader does NOT consult the class declarations
      # here — class objects are still resolved through
      # {#class_known?} and `Environment#singleton_for_name`.
      #
      # When `cache_store` is set, the loader fetches the entire
      # translated constant table once (per process) through
      # {Cache::RbsConstantTable.fetch} and answers point lookups
      # from it. Cold runs pay the translation cost up-front and
      # write the result to disk; warm runs skip the translation
      # entirely and pay only a `Marshal.load` of the table.
      def constant_type(name)
        rbs_name = parse_type_name(name)
        return nil unless rbs_name

        if cache_store
          constant_type_table[rbs_name.to_s]
        else
          translate_constant_decl(rbs_name)
        end
      rescue ::RBS::BaseError
        nil
      end

      private

      def constant_type_table
        @constant_type_table ||= begin
          require_relative "../cache/rbs_constant_table"
          Cache::RbsConstantTable.fetch(loader: self, store: cache_store)
        end
      end

      def known_class_names_set
        @known_class_names_set ||= begin
          require_relative "../cache/rbs_known_class_names"
          Cache::RbsKnownClassNames.fetch(loader: self, store: cache_store)
        end
      end

      def type_param_names_table
        @type_param_names_table ||= begin
          require_relative "../cache/rbs_class_type_param_names"
          Cache::RbsClassTypeParamNames.fetch(loader: self, store: cache_store)
        end
      end

      def cached_class_known(name)
        rbs_name = parse_type_name(name)
        return false unless rbs_name

        known_class_names_set.include?(rbs_name.to_s)
      rescue ::RBS::BaseError
        false
      end

      def translate_constant_decl(rbs_name)
        entry = env.constant_decls[rbs_name]
        return nil unless entry

        translated = Inference::RbsTypeTranslator.translate(entry.decl.type)
        translated unless translated.is_a?(Type::Bot)
      end

      def env
        @state[:env] ||= cache_store ? cached_env : build_env
      end

      def cached_env
        require_relative "../cache/rbs_environment"
        Cache::RbsEnvironment.fetch(loader: self, store: cache_store)
      end

      # Per-process Hash<String, RBS::Definition> for the instance
      # side. Loaded once on first miss through the
      # {Cache::RbsInstanceDefinitions} producer (single Marshal
      # blob); subsequent calls are pure Hash lookups. Cold runs
      # build every known class once and persist; warm runs (and
      # other loaders sharing the same Store) skip the
      # `RBS::DefinitionBuilder.build_instance` work entirely.
      def cached_instance_definition(class_name)
        instance_definitions_table[normalise_class_key(class_name)]
      end

      def instance_definitions_table
        @state[:instance_definitions_table] ||= begin
          require_relative "../cache/rbs_instance_definitions"
          Cache::RbsInstanceDefinitions.fetch(loader: self, store: cache_store)
        end
      end

      def cached_singleton_definition(class_name)
        singleton_definitions_table[normalise_class_key(class_name)]
      end

      def singleton_definitions_table
        @state[:singleton_definitions_table] ||= begin
          require_relative "../cache/rbs_instance_definitions"
          Cache::RbsSingletonDefinitions.fetch(loader: self, store: cache_store)
        end
      end

      # The cache producers persist class names in
      # `RBS::TypeName#to_s` form (top-level prefixed
      # `"::Hash"`); plain-name lookups (`"Hash"`) normalise
      # before the Hash query so callers stay agnostic to the
      # prefix.
      def normalise_class_key(class_name)
        s = class_name.to_s
        s.start_with?("::") ? s : "::#{s}"
      end

      def builder
        @state[:builder] ||= RBS::DefinitionBuilder.new(env: env)
      end

      def build_env
        self.class.build_env_for(libraries: @libraries, signature_paths: @signature_paths)
      end

      def build_instance_definition(class_name)
        rbs_name = parse_type_name(class_name)
        return nil unless rbs_name
        return nil unless env.class_decls.key?(rbs_name)

        builder.build_instance(rbs_name)
      rescue ::RBS::BaseError
        nil
      end

      def build_singleton_definition(class_name)
        rbs_name = parse_type_name(class_name)
        return nil unless rbs_name
        return nil unless env.class_decls.key?(rbs_name)

        builder.build_singleton(rbs_name)
      rescue ::RBS::BaseError
        nil
      end

      def parse_type_name(name)
        s = name.to_s
        return nil if s.empty?

        s = "::#{s}" unless s.start_with?("::")
        RBS::TypeName.parse(s)
      rescue ::RBS::BaseError
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
      rescue ::RBS::BaseError
        false
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
