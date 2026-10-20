# frozen_string_literal: true

require "date"
require_relative "../trinary"
require_relative "acceptance_router"
require_relative "plain_lattice"

module Rigor
  module Type
    # A literal carrier under ADR-3 OQ1 Option C (Hybrid). Wraps a Ruby literal value of one of the
    # supported immutable-ish classes. Compound literal shapes (Tuple, HashShape, Record) get dedicated
    # classes in later slices; Range is carried only when both static endpoints are known enough for
    # tuple slicing.
    #
    # See docs/adr/4-type-inference-engine.md for the tentative answer to the open question and
    # docs/type-specification/rigor-extensions.md for the refinement neighbourhood this carrier lives in.
    class Constant
      SCALAR_CLASSES = [
        Integer,
        Float,
        String,
        Symbol,
        Range,
        Rational,
        Complex,
        Regexp,
        Pathname,
        ::Set,
        # `Date` covers `DateTime` (a subclass). `Time` is core. Both arise only from deterministic
        # constructor folding (`Date.new` / `Time.utc`) — there is no Date / Time literal node — so a
        # `Constant` carrier is always sound.
        Date,
        Time,
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

        @value = freezable_carrier?(value) ? value.dup.freeze : value
        freeze
      end

      # Mutable-ish carriers are stored as a frozen copy so a later in-place mutation cannot rewrite the
      # literal under us. `Time` joins `String` / `Set` here: `Time#localtime` mutates the receiver's
      # zone in place, so the carrier holds a frozen copy (the catalog also blocklists the mutators).
      # `Date` is already immutable, but is duped-and-frozen for symmetry.
      def freezable_carrier?(value)
        value.is_a?(String) || value.is_a?(::Set) ||
          value.is_a?(Date) || value.is_a?(Time)
      end

      # `Date#inspect` / `DateTime#inspect` spell out the internal astronomical-Julian-day representation,
      # which is unreadable in a diagnostic. ISO-8601 is the compact, deterministic form. `Time#inspect`
      # is already compact (`2026-01-01 00:00:00 UTC`), so it keeps the default.
      def describe(_verbosity = :short)
        case value
        when Date then value.iso8601
        else value.inspect
        end
      end

      # RBS supports `Literal` types for booleans, nil, integer literals (positive and negative), symbol
      # literals, and string literals. Erasing to these preserves the carrier's precision at the RBS
      # boundary — `Constant<64>` round-trips as `64`, not as `Integer` — and
      # `RbsTypeTranslator#translate_literal` already maps the parsed RBS Literal back to `Constant`.
      # Scalar carriers without RBS Literal support (Float, Range, Rational, Complex, Regexp, Pathname)
      # keep their pre-existing widen-to-class-name behaviour because RBS rejects their literal spellings
      # as syntax errors. `Range` is generic (`Range[out E]`), and a bare `Range` fails `rbs validate`, so
      # it carries the class of its endpoints, or `untyped` when both are nil (#1891). `Set[unchecked out A]` is
      # generic too, and a set is mutable: the constant's elements are only what it held when it was built, and
      # `x << "a"` adds a member they do not name. It erases to `Set[untyped]`, as an Array or Hash literal's
      # element type is widened rather than pinned (#2177).
      def erase_to_rbs
        case value
        when true then "true"
        when false then "false"
        when nil then "nil"
        when Integer then value.to_s
        when Symbol, String then value.inspect
        when Range then "Range[#{range_element_rbs}]"
        when ::Set then "Set[untyped]"
        else value.class.name
        end
      end

      include Rigor::Type::PlainLattice

      include Rigor::Type::AcceptanceRouter

      # Two carriers are equal when they pin the same value, which for a Float is stricter than Ruby's `==`
      # (#1513): `0.0` and `-0.0` are distinct values (`1.0 / x` tells them apart), so `0.0 | -0.0` keeps both
      # members, and a NaN equals another NaN, so `==` stays reflexive and a union never collects one NaN member
      # per occurrence. A Complex compares its parts the same way.
      def ==(other)
        other.is_a?(Constant) && value.class == other.value.class && Constant.same_value?(value, other.value)
      end
      alias eql? ==

      def hash
        [Constant, value.class, Constant.value_key(value)].hash
      end

      # True when `left` and `right` (of one class) are the same value in the sense of {#==}.
      def self.same_value?(left, right)
        case left
        when Float then same_float?(left, right)
        when Complex then same_float?(left.real, right.real) && same_float?(left.imaginary, right.imaginary)
        else left == right
        end
      end

      def self.same_float?(left, right)
        return left == right unless left.is_a?(Float) && right.is_a?(Float)
        return right.nan? if left.nan?

        left.eql?(right) && (!left.zero? || (1.0 / left).positive? == (1.0 / right).positive?)
      end

      # A key whose `eql?` / `hash` agree with {.same_value?}: `uniq { |v| Constant.value_key(v) }` keeps
      # `0.0` and `-0.0` apart and folds every NaN into one. Any other value is its own key, so plain `uniq`
      # semantics are unchanged for it.
      def self.value_key(value)
        case value
        when Float then float_key(value)
        when Complex then [Complex, float_key(value.real), float_key(value.imaginary)]
        else value
        end
      end

      def self.float_key(value)
        return value unless value.is_a?(Float)
        return :nan if value.nan?

        value.zero? ? [Float, (1.0 / value)] : value
      end

      def inspect
        "#<Rigor::Type::Constant #{describe(:short)}>"
      end

      private

      def range_element_rbs
        classes = [value.begin, value.end].compact.map { |endpoint| endpoint.class.name }.uniq.sort
        classes.empty? ? "untyped" : classes.join(" | ")
      end
    end
  end
end
