# frozen_string_literal: true

require_relative "environment/class_registry"
require_relative "environment/rbs_loader"
require_relative "environment/reflection"
require_relative "environment/reporters"
require_relative "environment/hkt_registry_holder"
require_relative "environment/bundle_sig_discovery"
require_relative "environment/lockfile_resolver"
require_relative "environment/rbs_collection_discovery"
require_relative "environment/rbs_coverage_report"
require_relative "inference/synthetic_method_index"
require_relative "inference/project_patched_methods"
require_relative "inference/hkt_registry"
require_relative "builtins/hkt_builtins"
require_relative "type_node/name_scope"
require_relative "type_node/resolver_chain"

module Rigor
  # The engine's view of the type universe outside the current scope.
  # Slice 1 only exposed the class registry; Slice 4 adds the RBS loader,
  # which threads through ExpressionTyper and MethodDispatcher to type
  # constant references and method calls that the literal-typer and
  # constant-folding tiers cannot answer.
  #
  # See docs/internal-spec/inference-engine.md for the binding contract.
  class Environment
    DEFAULT_PROJECT_SIG_DIR = "sig"
    private_constant :DEFAULT_PROJECT_SIG_DIR

    # Slice A stdlib expansion. Stdlib libraries that
    # `Environment.for_project` loads on top of RBS core unless
    # the caller passes an explicit `libraries:` array. Each
    # entry MUST be a stdlib library name accepted by
    # `RBS::EnvironmentLoader#has_library?`; unknown libraries
    # MUST fail-soft (`RbsLoader#build_env` already filters
    # through `has_library?`). The default set covers the common
    # stdlib surface a Ruby program is likely to import
    # (`pathname`, `optparse`, `json`, `yaml`, `fileutils`,
    # `tempfile`, `uri`, `logger`, `date`) plus the analyzer-
    # adjacent gems shipping their own RBS in this bundle
    # (`prism`, `rbs`). On hosts where one of these libraries is
    # not installed, the loader silently drops it.
    #
    # Callers MAY add to the default by passing
    # `libraries: %w[csv ...]`; the explicit list is appended to
    # `DEFAULT_LIBRARIES` and de-duplicated. Callers that need
    # a strictly RBS-core view MUST construct an `RbsLoader`
    # directly instead of going through `for_project`.
    DEFAULT_LIBRARIES = %w[
      pathname optparse json yaml fileutils tempfile tmpdir
      stringio forwardable digest securerandom
      uri logger date
      pp delegate observable abbrev find tsort singleton
      shellwords benchmark base64 did_you_mean
      monitor mutex_m timeout
      open3 erb etc ipaddr bigdecimal bigdecimal-math
      prettyprint random-formatter time open-uri resolv
      csv pstore objspace io-console cgi cgi-escape
      strscan
      prism rbs
    ].freeze

    attr_reader :class_registry, :rbs_loader, :plugin_registry, :dependency_source_index,
                :reporters, :name_scope,
                :synthetic_method_index, :project_patched_methods

    # @param class_registry [Rigor::Environment::ClassRegistry]
    # @param rbs_loader [Rigor::Environment::RbsLoader, nil] when nil the
    #   environment is "RBS-blind"; useful in tests that want to assert
    #   how the engine behaves without RBS data. The default Environment
    #   wires the shared core loader, which is itself lazy: requesting an
    #   environment instance does NOT load RBS until a method or class
    #   query actually consults the loader.
    # @param plugin_registry [Rigor::Plugin::Registry, nil] v0.1.1
    #   Track 2 slice 7. The per-run plugin registry the
    #   inference engine consults at call sites for plugin
    #   `#flow_contribution_for` overrides. When nil (the
    #   default), no plugin-level return-type contribution
    #   participates — useful for tests, the `Environment.default`
    #   facade, and analyses that don't load plugins.
    # @param dependency_source_index [Rigor::Analysis::DependencySourceInference::Index, nil]
    #   ADR-10 slice 2b-ii. The per-run index of opt-in gem
    #   sources the dispatcher consults BELOW RBS dispatch.
    #   When nil (the default), no dep-source contribution
    #   participates and the dispatcher tier is a no-op.
    def initialize(class_registry: ClassRegistry.default, rbs_loader: nil, # rubocop:disable Metrics/ParameterLists
                   plugin_registry: nil, dependency_source_index: nil,
                   rbs_extended_reporter: nil, boundary_cross_reporter: nil,
                   synthetic_method_index: nil, project_patched_methods: nil,
                   hkt_registry: nil)
      @class_registry = class_registry
      @rbs_loader = rbs_loader
      @plugin_registry = plugin_registry
      @dependency_source_index = dependency_source_index
      # ADR-pending — reporters live in a mutable container so
      # long-lived integrations (LSP `ProjectContext`) can swap
      # them per `Runner.run` without rebuilding the env. The
      # existing `#rbs_extended_reporter` / `#boundary_cross_reporter`
      # accessors below preserve the public lookup shape.
      @reporters = Reporters.new(
        rbs_extended: rbs_extended_reporter,
        boundary_cross: boundary_cross_reporter
      )
      @synthetic_method_index = synthetic_method_index || Inference::SyntheticMethodIndex::EMPTY
      @project_patched_methods = project_patched_methods || Inference::ProjectPatchedMethods::EMPTY
      # ADR-20 slice 2c + 2e — the per-env HKT registry
      # consulted by the reducer when resolving `Type::App`
      # carriers. Defaults to {Inference::HktRegistry::EMPTY};
      # the {.default} / {.for_project} class methods seed it
      # with the bundled builtins (`json::value`, …) plus any
      # `%a{rigor:v1:hkt_register / hkt_define}` annotations
      # the RBS loader exposes. The hkt_registry getter
      # (defined below) MEMOIZES the result of merging the
      # base with the RBS scan so the scan is paid at most
      # once per Environment lifetime — and only when first
      # consulted, leaving fast paths like `rigor check
      # --cache-stats --no-stats` from doing the RBS env
      # build at all.
      @hkt_registry_base = hkt_registry || Inference::HktRegistry::EMPTY
      @hkt_registry_holder = HktRegistryHolder.new
      @name_scope = build_name_scope
      freeze
    end

    # ADR-20 slice 2e — lazy HKT registry getter. Merges the
    # base registry (Builtins seed) with the RBS env scan on
    # first call, then memoises. Single-threaded use only:
    # under the Ractor pool path each worker has its own
    # Environment so cross-worker mutation is impossible; the
    # LSP single-publish-at-a-time invariant serialises here.
    def hkt_registry
      @hkt_registry_holder.fetch do
        Inference::HktRegistry.scan_rbs_loader(
          @rbs_loader,
          base: @hkt_registry_base,
          reporter: rbs_extended_reporter
        )
      end
    end

    # Backwards-compatible reporter accessors — every existing
    # consumer (rbs_extended, method_dispatcher) calls these. The
    # frozen `@reporters` container is mutable for slot reassignment
    # via {#attach_reporters!} below.
    def rbs_extended_reporter
      @reporters.rbs_extended
    end

    def boundary_cross_reporter
      @reporters.boundary_cross
    end

    # Replaces the env's per-run reporter slots. Intended for
    # long-lived integrations (LSP `ProjectContext`) that share one
    # Environment instance across many `Runner.run` calls: each call
    # attaches its own fresh reporter pair so per-call diagnostic
    # events stay scoped to that call rather than accumulating
    # across publishes.
    #
    # Single-threaded use only. Concurrent publishes against one
    # Environment must serialise — the LSP `Server` debouncer +
    # synchronized writer already enforces this for the editor
    # path. The Ractor pool path builds a per-worker Environment
    # and does not reach this surface.
    def attach_reporters!(rbs_extended_reporter:, boundary_cross_reporter:)
      @reporters.rbs_extended = rbs_extended_reporter
      @reporters.boundary_cross = boundary_cross_reporter
      nil
    end

    class << self
      def default
        @default ||= new(
          rbs_loader: RbsLoader.default,
          hkt_registry: Builtins::HktBuiltins.registry
        ).freeze
      end

      # Builds an Environment that consults the project's local
      # signatures and any opt-in stdlib libraries on top of RBS core.
      #
      # @param root [String, Pathname] project root used to auto-detect
      #   the default signature path. Defaults to the current working
      #   directory.
      # @param libraries [Array<String, Symbol>] additional stdlib
      #   libraries to load on top of {DEFAULT_LIBRARIES}. The
      #   final list is the union of the two, de-duplicated while
      #   preserving order. Pass an empty array (the default) to
      #   load only the defaults.
      # @param signature_paths [Array<String, Pathname>, nil] explicit
      #   list of `sig/`-style directories. When `nil` (the default),
      #   the canonical project layout `<root>/sig` is used if it
      #   exists, otherwise no signature path is loaded.
      # @param cache_store [Rigor::Cache::Store, nil] persistent cache
      #   threaded into the underlying {Environment::RbsLoader} so
      #   constant lookups (and, in later v0.0.9 slices, other
      #   reflection artefacts) consult the cache. Pass `nil` (the
      #   default) to skip caching for this environment.
      # @return [Rigor::Environment]
      # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
      def for_project(root: Dir.pwd, libraries: [], signature_paths: nil, cache_store: nil,
                      plugin_registry: nil, dependency_source_index: nil,
                      rbs_extended_reporter: nil, boundary_cross_reporter: nil,
                      bundler_bundle_path: nil, bundler_auto_detect: false,
                      bundler_lockfile: nil,
                      rbs_collection_lockfile: nil, rbs_collection_auto_detect: false,
                      synthetic_method_index: nil, project_patched_methods: nil)
        resolved_paths = signature_paths || default_signature_paths(root)
        # O4 MVP — append per-gem `sig/` directories discovered
        # under the target project's bundler install root. Empty
        # array when neither an explicit path nor auto-detection
        # finds a bundle. Order: user `signature_paths:` win first
        # (semantic precedence inside `RbsLoader.build_env_for`);
        # gem-shipped sigs append last so user overrides stay
        # authoritative.
        #
        # O4 Layer 3 — when a Gemfile.lock is available (explicit
        # `bundler_lockfile:` or auto-detected next to the project
        # root), use the locked gem set to filter the discovered
        # `sig/` directories. Stale gems in the bundle install
        # tree (out-of-band installs, version drift after a
        # `bundle update`) are silently dropped so only gems the
        # project actually declares contribute RBS.
        locked = LockfileResolver.locked_gems(
          lockfile_path: bundler_lockfile,
          project_root: root,
          auto_detect: bundler_auto_detect
        )
        gem_sig_paths = BundleSigDiscovery.discover(
          bundle_path: bundler_bundle_path,
          project_root: root,
          auto_detect: bundler_auto_detect,
          locked_gems: locked.empty? ? nil : locked
        ).map(&:to_s)
        # O4 Layer 3 slice 2 — when `rbs collection install`
        # has been run for the target project, parse the
        # resulting `rbs_collection.lock.yaml` and feed each
        # gem's `<collection_path>/<name>/<version>/` directory
        # into `signature_paths:`. Stdlib-typed entries are
        # skipped (already covered by `DEFAULT_LIBRARIES`).
        collection_paths = RbsCollectionDiscovery.discover(
          lockfile_path: rbs_collection_lockfile,
          project_root: root,
          auto_detect: rbs_collection_auto_detect
        ).map(&:to_s)
        loader_signature_paths = resolved_paths + gem_sig_paths + collection_paths
        merged_libraries = (DEFAULT_LIBRARIES + libraries.map(&:to_s)).uniq
        loader = RbsLoader.new(
          libraries: merged_libraries,
          signature_paths: loader_signature_paths,
          cache_store: cache_store
        )
        # ADR-20 slice 2c + 2e — seed hkt_registry with the
        # bundled builtins. The Environment's `#hkt_registry`
        # getter then LAZILY merges in the RBS env scan on
        # first call so fast paths that don't consult HKT
        # (e.g. `rigor check --cache-stats --no-stats`) don't
        # pay the eager env-build cost up front. URI
        # collisions let the user-authored overlay win over
        # the bundled builtin (last-write-wins per ADR-20
        # OQ3 tentative).
        new(
          rbs_loader: loader,
          plugin_registry: plugin_registry,
          dependency_source_index: dependency_source_index,
          rbs_extended_reporter: rbs_extended_reporter,
          boundary_cross_reporter: boundary_cross_reporter,
          synthetic_method_index: synthetic_method_index,
          project_patched_methods: project_patched_methods,
          hkt_registry: Builtins::HktBuiltins.registry
        )
      end
      # rubocop:enable Metrics/MethodLength, Metrics/ParameterLists

      private

      def default_signature_paths(root)
        sig = Pathname(root) / DEFAULT_PROJECT_SIG_DIR
        sig.directory? ? [sig] : []
      end
    end

    # Resolves a constant name to a Rigor::Type::Nominal (the *instance*
    # type carrier). Consults the static class registry first (cheap,
    # hardcoded), then falls back to the RBS loader. Returns nil when
    # the name is unknown to both.
    #
    # NOTE: This is the construction helper for "an instance of class
    # `Foo`". For "the class object `Foo` itself" (the value of the
    # constant), use {#singleton_for_name} instead.
    def nominal_for_name(name)
      registered = class_registry.nominal_for_name(name)
      return registered if registered

      class_known_in_rbs?(name) ? Type::Combinator.nominal_of(name.to_s) : nil
    end

    # Resolves a constant name to a Rigor::Type::Singleton (the *class
    # object* carrier). The expression `Foo` evaluates to the class
    # object, whose RBS type is `singleton(Foo)` -- this method is the
    # corresponding Rigor construction helper.
    #
    # The lookup uses the same registry/RBS chain as {#nominal_for_name}
    # so a class is either known to both queries or to neither.
    def singleton_for_name(name)
      return nil unless class_known?(name)

      Type::Combinator.singleton_of(name.to_s)
    end

    # Slice A constant-value lookup. Returns the translated
    # `Rigor::Type` for an RBS-declared **non-class** constant
    # (`Rigor::Analysis::FactStore::BUCKETS: Array[Symbol]`,
    # `Rigor::Configuration::DEFAULT_PATH: String`, ...) or `nil`
    # when no RBS constant declaration covers `name`. This is the
    # value-bearing counterpart of {#singleton_for_name}, which
    # only resolves names that name a class or module. Callers
    # that need to type a `Prism::ConstantReadNode`/
    # `Prism::ConstantPathNode` MUST consult {#singleton_for_name}
    # first and fall through to this query when the constant is
    # not a class.
    def constant_for_name(name)
      return nil if rbs_loader.nil?

      rbs_loader.constant_type(name.to_s)
    end

    # Returns true when the constant name is known to either the static
    # registry or the RBS loader. Useful for callers that only need a
    # presence check without materialising a type carrier.
    def class_known?(name)
      return true if class_registry.nominal_for_name(name)

      class_known_in_rbs?(name)
    end

    # ADR-15 Phase 2b — returns the loader's read-only,
    # `Ractor.shareable?` query surface as a frozen
    # {Environment::Reflection}. Built lazily on first
    # access; subsequent calls return the same instance.
    # Returns `nil` when the environment carries no RBS
    # loader (test-only `Environment.new` without
    # `rbs_loader:`).
    def reflection
      @rbs_loader&.reflection
    end

    # Compares two class/module names using analyzer-owned class data.
    # Returns `:equal`, `:subclass`, `:superclass`, `:disjoint`, or
    # `:unknown`. The static registry handles built-ins cheaply; the RBS
    # loader handles project/stdlib classes without relying on host Ruby
    # constants being loaded.
    def class_ordering(lhs, rhs)
      lhs = normalize_class_name(lhs)
      rhs = normalize_class_name(rhs)
      return :equal if lhs == rhs

      registry_result = class_registry.class_ordering(lhs, rhs)
      return registry_result unless registry_result == :unknown

      return :unknown unless rbs_loader

      rbs_loader.class_ordering(lhs, rhs)
    end

    private

    def class_known_in_rbs?(name)
      return false unless rbs_loader

      rbs_loader.class_known?(name)
    end

    def normalize_class_name(name)
      name.to_s.delete_prefix("::")
    end

    # ADR-13 slice 3b — composes the per-run plugin-supplied
    # {Rigor::TypeNode::ResolverChain} into a single
    # {Rigor::TypeNode::NameScope} that the RBS::Extended
    # directive parser threads down to the
    # {Rigor::Builtins::ImportedRefinements::Resolver}. Returns
    # `nil` when no plugin contributes a type-node resolver so
    # the parser short-circuits the chain consultation and
    # behaves bit-for-bit like the v0.1.0 → v0.1.3 default.
    def build_name_scope
      return nil if @plugin_registry.nil? || @plugin_registry.empty?

      resolvers = @plugin_registry.type_node_resolvers
      return nil if resolvers.empty?

      TypeNode::NameScope.new(
        resolver: TypeNode::ResolverChain.new(resolvers),
        class_context: nil,
        type_alias_table: {}
      )
    end
  end
end
