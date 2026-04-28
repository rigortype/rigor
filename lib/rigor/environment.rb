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

    def self.default
      @default ||= new(rbs_loader: RbsLoader.default).freeze
    end

    # Resolves a constant name to a Rigor::Type::Nominal. Consults the
    # static class registry first (cheap, hardcoded), then falls back to
    # the RBS loader. Returns nil when the name is unknown to both.
    def nominal_for_name(name)
      registered = class_registry.nominal_for_name(name)
      return registered if registered
      return nil unless rbs_loader
      return nil unless rbs_loader.class_known?(name)

      Type::Combinator.nominal_of(name.to_s)
    end
  end
end
