# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # `Difference[base, removed]` — the value set of `base` minus
    # the value set of `removed`. Implements the point-removal
    # half of the OQ3 refinement-carrier strategy
    # ([ADR-3](docs/adr/3-type-representation.md), Working
    # Decision Option C):
    #
    #   non-empty-string   = Difference[Nominal[String], Constant[""]]
    #   non-zero-int       = Difference[Nominal[Integer], Constant[0]]
    #   non-empty-array[T] = Difference[Nominal[Array, [T]], Tuple[]]
    #   non-empty-hash[K,V] = Difference[Nominal[Hash, [K,V]], HashShape{}]
    #
    # The carrier itself is structural: it stores `base` and
    # `removed` as inner `Type` references and answers projection
    # / acceptance / display questions by composing those inner
    # answers per the lattice algebra in
    # [`value-lattice.md`](docs/type-specification/value-lattice.md).
    # The canonical-name registry (display side) lives in
    # `Rigor::Type::Combinator` and prints kebab-case names like
    # `non-empty-string` for the recognised shapes; unrecognised
    # differences fall back to the raw `base - removed`
    # operator form per [`type-operators.md`](docs/type-specification/type-operators.md).
    #
    # Construction goes through `Type::Combinator.difference` /
    # `Combinator.non_empty_string` etc. — direct `.new` calls
    # are an internal contract; callers MUST ensure both bounds
    # are valid `Rigor::Type` values and that `removed` is a
    # subtype-or-equal of `base` (otherwise the difference does
    # not narrow anything and a normalisation upstream should
    # collapse to `base`).
    class Difference
      attr_reader :base, :removed

      def initialize(base, removed)
        @base = base
        @removed = removed
        freeze
      end

      def describe(verbosity = :short)
        named = canonical_name
        return named if named

        "#{base.describe(verbosity)} - #{removed.describe(verbosity)}"
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
        other.is_a?(Difference) && base == other.base && removed == other.removed
      end
      alias eql? ==

      def hash
        [Difference, base, removed].hash
      end

      def inspect
        "#<Rigor::Type::Difference #{describe(:short)}>"
      end

      private

      # Renders the kebab-case shorthand for recognised
      # imported-built-in shapes. Parameterised bases keep their
      # type-args in the canonical form (`non-empty-array[T]`,
      # `non-empty-hash[K, V]`) so element-precision survives the
      # display round-trip. Unrecognised shapes fall back to the
      # raw `base - removed` operator form.
      #
      # The recognised set is kept in sync with the imported-built-in
      # catalogue ([`imported-built-in-types.md`](docs/type-specification/imported-built-in-types.md)).
      def canonical_name
        return nil unless base.is_a?(Nominal)

        send(CANONICAL_HANDLERS[base.class_name] || :no_canonical_name)
      end

      CANONICAL_HANDLERS = {
        "String" => :string_canonical_name,
        "Integer" => :integer_canonical_name,
        "Array" => :array_canonical_name_if_empty,
        "Hash" => :hash_canonical_name_if_empty
      }.freeze
      private_constant :CANONICAL_HANDLERS

      def no_canonical_name
        nil
      end

      def string_canonical_name
        return nil unless removed.is_a?(Constant) && removed.value == ""

        "non-empty-string"
      end

      def integer_canonical_name
        return nil unless removed.is_a?(Constant) && removed.value.is_a?(Integer) && removed.value.zero?

        "non-zero-int"
      end

      def array_canonical_name_if_empty
        return nil unless removed.is_a?(Tuple) && removed.elements.empty?

        array_canonical_name
      end

      def hash_canonical_name_if_empty
        return nil unless removed.is_a?(HashShape) && removed.pairs.empty?

        hash_canonical_name
      end

      def array_canonical_name
        elem = base.type_args.first
        return "non-empty-array" if elem.nil?

        "non-empty-array[#{elem.describe}]"
      end

      def hash_canonical_name
        key, value = base.type_args
        return "non-empty-hash" if key.nil? || value.nil?

        "non-empty-hash[#{key.describe}, #{value.describe}]"
      end
    end
  end
end
