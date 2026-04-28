# frozen_string_literal: true

require_relative "../type"

module Rigor
  class Environment
    # Resolves Ruby Class/Module objects to Rigor::Type::Nominal instances.
    # In Slice 1 this is a hardcoded list of core classes that the literal
    # typer needs. Slice 3 extends the registry by reading RBS Definitions
    # through Rigor::Environment::RbsLoader.
    #
    # See docs/internal-spec/inference-engine.md for the binding contract
    # (the SLICE_1_BUILT_INS list MUST always be recognised).
    class ClassRegistry
      SLICE_1_BUILT_INS = [
        Integer,
        Float,
        String,
        Symbol,
        NilClass,
        TrueClass,
        FalseClass,
        Object,
        BasicObject
      ].freeze

      class << self
        def default
          @default ||= build_default
        end

        private

        def build_default
          new.tap do |registry|
            SLICE_1_BUILT_INS.each { |klass| registry.register(klass) }
          end.freeze
        end
      end

      def initialize
        @nominals = {}
      end

      def register(class_object)
        raise ArgumentError, "expected Class or Module, got #{class_object.class}" unless class_object.is_a?(Module)
        raise ArgumentError, "anonymous class has no name" if class_object.name.nil?

        @nominals[class_object.name] ||= Type::Combinator.nominal_of(class_object)
        self
      end

      def registered?(class_object)
        return false unless class_object.is_a?(Module) && class_object.name

        @nominals.key?(class_object.name)
      end

      def nominal_for(class_object)
        unless registered?(class_object)
          raise KeyError, "Rigor::Environment::ClassRegistry has no entry for #{class_object.inspect}"
        end

        @nominals.fetch(class_object.name)
      end
    end
  end
end
