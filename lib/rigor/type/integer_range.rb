# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # A bounded integer range carrier. Each bound is either an `Integer`
    # or one of the symbolic infinities `:neg_infinity` / `:pos_infinity`.
    # Inspired by PHPStan's `int<min, max>` family — the named aliases
    # `positive-int` (1..), `non-negative-int` (0..), `negative-int`
    # (..-1), `non-positive-int` (..0) all surface through this single
    # carrier and are recovered in `describe` for human-friendly output.
    #
    # Constraints on construction:
    # - both bounds must be either `Integer` or one of the two infinity
    #   sentinels;
    # - if both bounds are concrete, `min <= max` must hold;
    # - the universal case `(-∞, +∞)` is structurally distinct from
    #   `Nominal[Integer]` — it carries no extra information today but
    #   keeps the carrier closed under range narrowing.
    #
    # Erasure to RBS is always "Integer": RBS itself does not natively
    # express bounded integer ranges.
    class IntegerRange
      NEG_INFINITY = :neg_infinity
      POS_INFINITY = :pos_infinity
      INFINITIES = [NEG_INFINITY, POS_INFINITY].freeze

      attr_reader :min, :max

      def initialize(min, max)
        validate_bound!(min, "min")
        validate_bound!(max, "max")
        if min.is_a?(Integer) && max.is_a?(Integer) && min > max
          raise ArgumentError, "IntegerRange requires min (#{min}) <= max (#{max})"
        end
        if min == POS_INFINITY || max == NEG_INFINITY
          raise ArgumentError, "IntegerRange bounds out of order: min=#{min.inspect}, max=#{max.inspect}"
        end

        @min = min
        @max = max
        freeze
      end

      def universal?
        min == NEG_INFINITY && max == POS_INFINITY
      end

      def finite?
        min.is_a?(Integer) && max.is_a?(Integer)
      end

      def cardinality
        finite? ? (max - min + 1) : Float::INFINITY
      end

      def covers?(int)
        return false unless int.is_a?(Integer)

        int.between?(lower, upper)
      end

      # Returns the lower bound as a numeric (with `-Float::INFINITY` for
      # `:neg_infinity`). Use this in arithmetic comparisons; never compare
      # `:neg_infinity` directly with an `Integer`.
      def lower
        min == NEG_INFINITY ? -Float::INFINITY : min
      end

      def upper
        max == POS_INFINITY ? Float::INFINITY : max
      end

      ALIAS_NAMES = {
        [NEG_INFINITY, POS_INFINITY] => "int",
        [1, POS_INFINITY] => "positive-int",
        [0, POS_INFINITY] => "non-negative-int",
        [NEG_INFINITY, -1] => "negative-int",
        [NEG_INFINITY, 0] => "non-positive-int"
      }.freeze

      def describe(_verbosity = :short)
        ALIAS_NAMES[[min, max]] || generic_description
      end

      def generic_description
        return "int<#{min}, max>" if max == POS_INFINITY
        return "int<min, #{max}>" if min == NEG_INFINITY

        "int<#{min}, #{max}>"
      end

      def erase_to_rbs
        "Integer"
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

      def accepts(other, mode: :gradual)
        Inference::Acceptance.accepts(self, other, mode: mode)
      end

      def ==(other)
        other.is_a?(IntegerRange) && min == other.min && max == other.max
      end
      alias eql? ==

      def hash
        [IntegerRange, min, max].hash
      end

      def inspect
        "#<Rigor::Type::IntegerRange #{describe(:short)}>"
      end

      private

      def validate_bound!(bound, label)
        return if bound.is_a?(Integer) || INFINITIES.include?(bound)

        raise ArgumentError,
              "IntegerRange #{label} must be Integer or :neg_infinity/:pos_infinity, got #{bound.inspect}"
      end
    end
  end
end
