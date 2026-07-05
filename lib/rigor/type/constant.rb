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
      # as syntax errors.
      def erase_to_rbs
        case value
        when true then "true"
        when false then "false"
        when nil then "nil"
        when Integer then value.to_s
        when Symbol, String then value.inspect
        else value.class.name
        end
      end

      include Rigor::Type::PlainLattice

      include Rigor::Type::AcceptanceRouter

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
