# frozen_string_literal: true

require_relative "environment/class_registry"

module Rigor
  # The engine's view of the type universe outside the current scope.
  # Slice 1 only exposes the class registry; later slices add the RBS
  # loader and fact-store access surfaces.
  #
  # See docs/internal-spec/inference-engine.md for the binding contract.
  class Environment
    attr_reader :class_registry

    def initialize(class_registry: ClassRegistry.default)
      @class_registry = class_registry
      freeze
    end

    def self.default
      @default ||= new.freeze
    end
  end
end
