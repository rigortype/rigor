# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # A scalar literal carrier under ADR-3 OQ1 Option C (Hybrid). Wraps a
    # Ruby literal value of one of the supported scalar classes. Compound
    # literal shapes (Tuple, HashShape, Record) get dedicated classes in
    # later slices.
    #
    # See docs/adr/4-type-inference-engine.md for the tentative answer to
    # the open question and docs/type-specification/rigor-extensions.md for
    # the refinement neighbourhood this carrier lives in.
    class Constant
      SCALAR_CLASSES = [
        Integer,
        Float,
        String,
        Symbol,
        Rational,
        Complex,
        TrueClass,
        FalseClass,
        NilClass
      ].freeze

      RBS_LITERAL_CLASSES = {
        TrueClass => "true",
        FalseClass => "false",
        NilClass => "nil"
      }.freeze

      attr_reader :value

      def initialize(value)
        unless SCALAR_CLASSES.any? { |klass| value.is_a?(klass) }
          raise ArgumentError, "Rigor::Type::Constant only carries scalar literals; got #{value.class}"
        end

        @value = value.is_a?(String) ? value.dup.freeze : value
        freeze
      end

      def describe(_verbosity = :short)
        value.inspect
      end

      def erase_to_rbs
        case value
        when true then "true"
        when false then "false"
        when nil then "nil"
        else value.class.name
        end
      end

      def top
        Trinary.no
      end

      def bot
        Trinary.no
      end

      def dynamic
        Trinary.no
      end

      def ==(other)
        other.is_a?(Constant) && value.class == other.value.class && value == other.value
      end
      alias eql? ==

      def hash
        [Constant, value.class, value].hash
      end

      def inspect
        "#<Rigor::Type::Constant #{describe(:short)}>"
      end
    end
  end
end
