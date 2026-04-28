# frozen_string_literal: true

require_relative "../type"

module Rigor
  class Environment
    # Resolves Ruby Class/Module objects to Rigor::Type::Nominal instances.
    # The hardcoded list spans the core classes the literal typer (Slice 1)
    # and the constant-resolution path (Slice 2 strengthening) need.
    # Slice 4 will extend the registry by reading RBS Definitions through
    # Rigor::Environment::RbsLoader.
    #
    # See docs/internal-spec/inference-engine.md for the binding contract
    # (every entry below MUST always be recognised).
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

      # Common Ruby core classes that user code routinely names by constant
      # reference. Adding them to the registry lets `nominal_for_name`
      # resolve `Array`, `Hash`, etc. without each call site re-listing
      # them; Slice 4's RBS loader will subsume these once it lands.
      SLICE_2_BUILT_INS = [
        Array,
        Hash,
        Range,
        Regexp,
        Proc,
        Method,
        Module,
        Class,
        Numeric,
        Comparable,
        Enumerable,
        Exception,
        StandardError,
        RuntimeError,
        ArgumentError,
        TypeError,
        NameError,
        NoMethodError,
        KeyError,
        IndexError,
        RangeError,
        ZeroDivisionError,
        IO,
        File,
        Dir,
        Encoding
      ].freeze

      CORE_BUILT_INS = (SLICE_1_BUILT_INS + SLICE_2_BUILT_INS).freeze

      class << self
        def default
          @default ||= build_default
        end

        private

        def build_default
          new.tap do |registry|
            CORE_BUILT_INS.each { |klass| registry.register(klass) }
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

      # Nil-safe lookup by class name. Accepts Symbol or String. Returns the
      # registered Rigor::Type::Nominal, or nil when the name is unknown.
      # Used by ExpressionTyper to resolve Prism::ConstantReadNode and
      # Prism::ConstantPathNode under the fail-soft policy: unknown names
      # MUST NOT raise and MUST flow through the engine's tracer.
      def nominal_for_name(name)
        return nil if name.nil?

        @nominals[name.to_s]
      end
    end
  end
end
