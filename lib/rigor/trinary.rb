# frozen_string_literal: true

module Rigor
  # Three-valued logic value object shared by capability queries, relational
  # queries, and any analyzer surface that distinguishes "proven yes",
  # "proven no", and "cannot prove either".
  #
  # See docs/type-specification/relations-and-certainty.md for semantics and
  # docs/internal-spec/internal-type-api.md for the contract.
  class Trinary
    VALUES = %i[yes no maybe].freeze

    class << self
      def yes
        @yes ||= new(:yes).freeze
      end

      def no
        @no ||= new(:no).freeze
      end

      def maybe
        @maybe ||= new(:maybe).freeze
      end

      def from_symbol(symbol)
        case symbol
        when :yes then yes
        when :no then no
        when :maybe then maybe
        else
          raise ArgumentError, "unknown trinary value: #{symbol.inspect}"
        end
      end
    end

    attr_reader :value

    def initialize(value)
      raise ArgumentError, "unknown trinary value: #{value.inspect}" unless VALUES.include?(value)

      @value = value
    end

    def yes?
      value == :yes
    end

    def no?
      value == :no
    end

    def maybe?
      value == :maybe
    end

    def negate
      case value
      when :yes then self.class.no
      when :no then self.class.yes
      when :maybe then self.class.maybe
      end
    end

    # Conjunction. yes & yes = yes, no with anything = no, otherwise maybe.
    def and(other)
      coerced = coerce(other)
      return self.class.no if no? || coerced.no?
      return self.class.yes if yes? && coerced.yes?

      self.class.maybe
    end

    # Disjunction. yes with anything = yes, no & no = no, otherwise maybe.
    def or(other)
      coerced = coerce(other)
      return self.class.yes if yes? || coerced.yes?
      return self.class.no if no? && coerced.no?

      self.class.maybe
    end

    def ==(other)
      other.is_a?(Trinary) && value == other.value
    end
    alias eql? ==

    def hash
      value.hash
    end

    def to_s
      value.to_s
    end

    def inspect
      "#<Rigor::Trinary #{value}>"
    end

    private

    def coerce(other)
      return other if other.is_a?(Trinary)

      raise TypeError, "expected Rigor::Trinary, got #{other.class}"
    end
  end
end
