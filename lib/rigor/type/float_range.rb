# frozen_string_literal: true

require_relative "../trinary"
require_relative "acceptance_router"
require_relative "plain_lattice"

module Rigor
  module Type
    # A bounded float range carrier: every `Float` that the Ruby range literal it displays as would
    # `cover?` (ADR-109 WD4). Bounds are doubles; `-Float::INFINITY` and `Float::INFINITY` are ordinary
    # bounds, never sentinels, because Ruby orders them. The range may exclude its end (`0.0...1.0`)
    # and never its beginning, because Ruby's literal has no exclusive begin.
    #
    # No bounded range contains NaN: `(a..b).cover?(Float::NAN)` is false for every `a` and `b`, so
    # the range from `-Float::INFINITY` to `Float::INFINITY` is "every Float except NaN"
    # (`non-nan-float`), not `Float`. The whole of `Float` (`nil..nil` in Ruby, which does cover NaN)
    # is never a carrier; the payload builder normalises it to `Nominal[Float]`.
    #
    # Two spellings bound the same set when their ends are neighbouring doubles: `0.0...1.0` and
    # `0.0..1.0.prev_float` cover the same floats. Equality, hashing and containment run on the
    # canonical closed form (`canonical_max`); `describe` keeps the written form.
    #
    # Erasure to RBS is always "Float".
    class FloatRange
      attr_reader :min, :max

      def initialize(min, max, exclude_end: false)
        validate_bound!(min, "min")
        validate_bound!(max, "max")
        # `-0.0` and `0.0` are one point in the order (`-0.0 == 0.0`, `(-0.0..0.0).cover?(0.0)`); keep
        # the one spelling so the display cannot suggest two ranges.
        @min = min.zero? ? 0.0 : min
        @max = max.zero? ? 0.0 : max
        @exclude_end = exclude_end == true
        if @min > canonical_max
          raise ArgumentError, "FloatRange #{Range.new(@min, @max, @exclude_end).inspect} is empty"
        end

        freeze
      end

      def exclude_end?
        @exclude_end
      end

      # The greatest double the range contains. `Float::INFINITY.prev_float` is `Float::MAX`, so an
      # exclusive infinite end reads as "finite above".
      def canonical_max
        @exclude_end ? max.prev_float : max
      end

      # Every Float except NaN.
      def universal?
        min == -Float::INFINITY && canonical_max == Float::INFINITY
      end

      # Ruby's own predicate is the definition: the carrier covers `value` exactly when the range it
      # displays as does.
      def covers?(value)
        return false unless value.is_a?(Float)

        Range.new(min, max, @exclude_end).cover?(value)
      end

      # Keyed by the canonical closed bounds so a written `-Float::MAX...Float::INFINITY` reads as the
      # set it is.
      ALIAS_NAMES = Ractor.make_shareable({
                                            [-Float::INFINITY, Float::INFINITY] => "non-nan-float",
                                            [-Float::MAX, Float::MAX] => "finite-float"
                                          })

      def describe(_verbosity = :short)
        ALIAS_NAMES[[min, canonical_max]] || generic_description
      end

      # The written form: an infinite bound is left out where Ruby's literal can (beginless, endless),
      # spelled `Float::INFINITY` where it cannot (`...Float::INFINITY` is "finite above"), and the two
      # extreme finite doubles read as the constants a Rubyist would write.
      def generic_description
        op = @exclude_end ? "..." : ".."
        lo = min == -Float::INFINITY ? "" : float_literal(min)
        hi = max == Float::INFINITY && !@exclude_end ? "" : float_literal(max)
        "Float[#{lo}#{op}#{hi}]"
      end

      def erase_to_rbs
        "Float"
      end

      include Rigor::Type::PlainLattice

      include Rigor::Type::AcceptanceRouter

      # Hand-written rather than `value_fields`: two carriers are the same type when they cover the
      # same doubles, whatever end they were written with.
      def ==(other)
        other.is_a?(FloatRange) && min == other.min && canonical_max == other.canonical_max
      end
      alias eql? ==

      def hash
        [self.class, min, canonical_max].hash
      end

      def inspect
        "#<Rigor::Type::FloatRange #{describe(:short)}>"
      end

      private

      def float_literal(value)
        case value
        when Float::INFINITY then "Float::INFINITY"
        when -Float::INFINITY then "-Float::INFINITY"
        when Float::MAX then "Float::MAX"
        when -Float::MAX then "-Float::MAX"
        else value.inspect
        end
      end

      def validate_bound!(bound, label)
        return if bound.is_a?(Float) && !bound.nan?

        raise ArgumentError, "FloatRange #{label} must be a non-NaN Float, got #{bound.inspect}"
      end
    end
  end
end
