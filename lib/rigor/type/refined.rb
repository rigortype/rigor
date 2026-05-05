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
      # built-in catalogue.
      #
      # Recogniser policy:
      #
      # - `:numeric` is deliberately conservative — only decimal
      #   integer and plain-decimal-fraction strings are
      #   recognised, mirroring `imported-built-in-types.md`'s
      #   "Rigor's numeric-string predicate" wording. Looser
      #   forms (scientific, hex, rational) MAY join later
      #   without breaking the registry contract.
      # - `:decimal_int` is "what `Integer(s, 10)` would parse
      #   without remainder" — one or more decimal digits,
      #   optional leading sign, no whitespace, no fractional
      #   tail.
      # - `:octal_int` and `:hex_int` REQUIRE their conventional
      #   prefix (`0o` / `0O` / leading `0` for octal; `0x` /
      #   `0X` for hex) so the predicate is disjoint from
      #   `:decimal_int`. A bare `"755"` is decimal-int-string,
      #   not octal-int-string. This matches the typical user
      #   intent — a refinement marks a string that "looks like
      #   octal", not "happens to be base-8 valid".
      NUMERIC_STRING_PATTERN = /\A-?\d+(?:\.\d+)?\z/
      DECIMAL_INT_STRING_PATTERN = /\A-?\d+\z/
      OCTAL_INT_STRING_PATTERN = /\A-?(?:0[oO][0-7]+|0[0-7]+)\z/
      HEX_INT_STRING_PATTERN = /\A-?0[xX][0-9a-fA-F]+\z/
      private_constant :NUMERIC_STRING_PATTERN, :DECIMAL_INT_STRING_PATTERN,
                       :OCTAL_INT_STRING_PATTERN, :HEX_INT_STRING_PATTERN

      PREDICATES = {
        lowercase: ->(v) { v.is_a?(String) && v == v.downcase },
        not_lowercase: ->(v) { v.is_a?(String) && v != v.downcase },
        uppercase: ->(v) { v.is_a?(String) && v == v.upcase },
        numeric: ->(v) { v.is_a?(String) && NUMERIC_STRING_PATTERN.match?(v) },
        decimal_int: ->(v) { v.is_a?(String) && DECIMAL_INT_STRING_PATTERN.match?(v) },
        octal_int: ->(v) { v.is_a?(String) && OCTAL_INT_STRING_PATTERN.match?(v) },
        hex_int: ->(v) { v.is_a?(String) && HEX_INT_STRING_PATTERN.match?(v) },
        # `literal-string` is a flow-tracked predicate, not a value-
        # level predicate: a String is literal-string when it is
        # known to come from a source-code literal (or composition
        # of literals). Every concrete `Constant<String>` is
        # already literal by construction, so the inspection
        # recogniser returns true for any String — the property is
        # really tracked in the flow analysis (interpolation,
        # concatenation, RBS::Extended `return: literal-string`)
        # rather than recovered by inspecting an arbitrary string.
        literal_string: ->(v) { v.is_a?(String) }
      }.freeze

      # Maps `[base_class_name, predicate_id]` pairs to their
      # kebab-case canonical name. Registered shapes print
      # through `describe`; unregistered combinations fall back
      # to the operator form.
      CANONICAL_NAMES = {
        ["String", :lowercase] => "lowercase-string",
        ["String", :not_lowercase] => "non-lowercase-string",
        ["String", :uppercase] => "uppercase-string",
        ["String", :numeric] => "numeric-string",
        ["String", :decimal_int] => "decimal-int-string",
        ["String", :octal_int] => "octal-int-string",
        ["String", :hex_int] => "hex-int-string",
        ["String", :literal_string] => "literal-string"
      }.freeze
      private_constant :CANONICAL_NAMES

      # Bidirectional `predicate_id ↔ complement_predicate_id`
      # registry. `~Refined[base, p]` narrows to
      # `Refined[base, COMPLEMENT_PAIRS[p]]` when the part is the
      # refinement's base — the precise carrier the spec promises
      # under the `~T` operator. Predicates without a registered
      # complement fall back to the imprecise but sound
      # `Difference[part, refined]` carrier from the existing
      # narrowing rule.
      #
      # Adding a new pair here is an additive change: register the
      # complement predicate in {PREDICATES}, give it a kebab-case
      # canonical name in {CANONICAL_NAMES}, and add the bidirectional
      # entry below. No call site needs to know about the new pair —
      # `complement_refined` consults this map and routes through
      # the registered complement automatically.
      COMPLEMENT_PAIRS = {
        lowercase: :not_lowercase,
        not_lowercase: :lowercase
      }.freeze
      private_constant :COMPLEMENT_PAIRS

      # @return [Symbol, nil] the registered complement predicate
      #   id, or nil when no pair is registered for this predicate.
      def complement_predicate_id
        COMPLEMENT_PAIRS[predicate_id]
      end

      private

      def canonical_name
        return nil unless base.is_a?(Nominal)

        CANONICAL_NAMES[[base.class_name, predicate_id]]
      end
    end
  end
end
