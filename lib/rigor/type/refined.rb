# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # `Refined[base, predicate_id]` — predicate-subset half of
    # the OQ3 refinement-carrier strategy
    # ([ADR-3](docs/adr/3-type-representation.md), Working
    # Decision Option C). Sibling of `Type::Difference`, which
    # carries the point-removal half.
    #
    #   lowercase-string = Refined[Nominal[String], :lowercase]
    #   uppercase-string = Refined[Nominal[String], :uppercase]
    #   numeric-string   = Refined[Nominal[String], :numeric]
    #
    # The carrier wraps a base type and a `predicate_id` Symbol
    # drawn from {PREDICATES}. The recogniser is invoked at
    # constant-fold and acceptance time over a `Constant<base>`
    # value; for non-Constant receivers the carrier is a marker
    # the catalog tier consults to project `String#downcase` /
    # `String#upcase` (etc.) into the matching refinement.
    #
    # Display routes through {CANONICAL_NAMES}: registered
    # `(base_class_name, predicate_id)` pairs print in their
    # kebab-case spelling (`lowercase-string`); unregistered
    # combinations fall back to the `base & predicate?` operator
    # form per
    # [`type-operators.md`](docs/type-specification/type-operators.md).
    #
    # Construction MUST go through `Type::Combinator.refined` /
    # the per-name factories (`Combinator.lowercase_string`,
    # `Combinator.uppercase_string`, `Combinator.numeric_string`).
    # Direct `.new` is an internal escape hatch for tests and
    # combinator's own implementation.
    class Refined
      attr_reader :base, :predicate_id

      def initialize(base, predicate_id)
        raise ArgumentError, "predicate_id must be a Symbol" unless predicate_id.is_a?(Symbol)

        @base = base
        @predicate_id = predicate_id
        freeze
      end

      def describe(verbosity = :short)
        named = canonical_name
        return named if named

        "#{base.describe(verbosity)} & #{predicate_id}?"
      end

      # Erases to the base nominal: every refinement MUST erase
      # to its base per [`rbs-erasure.md`](docs/type-specification/rbs-erasure.md).
      def erase_to_rbs
        base.erase_to_rbs
      end

      def top
        Trinary.no
      end

      def bot
        Trinary.no
      end

      def dynamic
        base.respond_to?(:dynamic) ? base.dynamic : Trinary.no
      end

      def accepts(other, mode: :gradual)
        Inference::Acceptance.accepts(self, other, mode: mode)
      end

      def ==(other)
        other.is_a?(Refined) && base == other.base && predicate_id == other.predicate_id
      end
      alias eql? ==

      def hash
        [Refined, base, predicate_id].hash
      end

      def inspect
        "#<Rigor::Type::Refined #{describe(:short)}>"
      end

      # Recognises a Ruby value against this carrier's
      # predicate. The trinary return is intentional: `true` /
      # `false` when the predicate registry decides, `nil`
      # when the predicate is unknown to the registry, so
      # callers (today {Inference::Acceptance}) can fall
      # through to gradual-mode `:maybe`.
      # rubocop:disable Style/ReturnNilInPredicateMethodDefinition
      def matches?(value)
        recogniser = PREDICATES[predicate_id]
        return nil if recogniser.nil?

        !!recogniser.call(value)
      end
      # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

      # `predicate_id => recogniser` table. The recogniser is
      # called with a Ruby value (typically the inner `value`
      # of a `Constant`) and returns truthy when the value
      # satisfies the predicate. The recogniser MUST be total
      # (return false rather than raise) over arbitrary input,
      # so callers can pass any `Constant#value` without a
      # type-prefilter.
      #
      # Plugin-contributed predicates land here once ADR-2 is
      # in flight; today the table is closed over the v0.0.4
      # built-in catalogue. The recogniser for `:numeric` is
      # deliberately conservative — only decimal integer and
      # plain-decimal-fraction strings are recognised, mirroring
      # `imported-built-in-types.md`'s "Rigor's numeric-string
      # predicate" wording. Looser forms (scientific, hex,
      # rational) MAY join the recogniser later without breaking
      # the registry contract.
      NUMERIC_STRING_PATTERN = /\A-?\d+(?:\.\d+)?\z/
      private_constant :NUMERIC_STRING_PATTERN

      PREDICATES = {
        lowercase: ->(v) { v.is_a?(String) && v == v.downcase },
        uppercase: ->(v) { v.is_a?(String) && v == v.upcase },
        numeric: ->(v) { v.is_a?(String) && NUMERIC_STRING_PATTERN.match?(v) }
      }.freeze

      # Maps `[base_class_name, predicate_id]` pairs to their
      # kebab-case canonical name. Registered shapes print
      # through `describe`; unregistered combinations fall back
      # to the operator form.
      CANONICAL_NAMES = {
        ["String", :lowercase] => "lowercase-string",
        ["String", :uppercase] => "uppercase-string",
        ["String", :numeric] => "numeric-string"
      }.freeze
      private_constant :CANONICAL_NAMES

      private

      def canonical_name
        return nil unless base.is_a?(Nominal)

        CANONICAL_NAMES[[base.class_name, predicate_id]]
      end
    end
  end
end
