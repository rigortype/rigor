# frozen_string_literal: true

require_relative "environment/class_registry"
require_relative "environment/rbs_loader"

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
      pathname optparse json yaml fileutils tempfile uri logger date
      prism rbs
    ].freeze

    attr_reader :class_registry, :rbs_loader

    # @param class_registry [Rigor::Environment::ClassRegistry]
    # @param rbs_loader [Rigor::Environment::RbsLoader, nil] when nil the
    #   environment is "RBS-blind"; useful in tests that want to assert
    #   how the engine behaves without RBS data. The default Environment
    #   wires the shared core loader, which is itself lazy: requesting an
    #   environment instance does NOT load RBS until a method or class
    #   query actually consults the loader.
    def initialize(class_registry: ClassRegistry.default, rbs_loader: nil)
      @class_registry = class_registry
      @rbs_loader = rbs_loader
      freeze
    end

    class << self
      def default
        @default ||= new(rbs_loader: RbsLoader.default).freeze
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
      # @return [Rigor::Environment]
      def for_project(root: Dir.pwd, libraries: [], signature_paths: nil)
        resolved_paths = signature_paths || default_signature_paths(root)
        merged_libraries = (DEFAULT_LIBRARIES + libraries.map(&:to_s)).uniq
        loader = RbsLoader.new(libraries: merged_libraries, signature_paths: resolved_paths)
        new(rbs_loader: loader)
      end

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
  end
end
