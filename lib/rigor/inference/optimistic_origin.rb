# frozen_string_literal: true

module Rigor
  module Inference
    # Marks a value whose *nil-freeness* rests on Rigor's deliberate choice to ignore core RBS's
    # `%a{implicitly-returns-nil}` annotation rather than on the value's class. See
    # docs/internal-spec/inference-engine.md § "That deferred-to answer is nil-free for a lookup that can
    # miss": `Hash#[]` reads as `V` and `Array#first` as `E` because pessimising them to `V?` costs 25
    # measured false positives on Rigor's own `lib`. The consequence the spec draws is that such a value is
    # **optimistic, not proof** — `MAP[key]` reading as `"x" | "y"` asserts nothing about whether the key was
    # present.
    #
    # A side channel in the ADR-75 / ADR-82 sense: it never participates in subtyping, consistency,
    # normalization or erasure, and no diagnostic fires from it. It differs from {DynamicOrigin} in what it
    # attaches to — the value here is *not* `Dynamic`; it is an ordinary `Union` / `Constant` / `Nominal`
    # that happens to have been produced optimistically.
    #
    # Issue #286: the `if` / `unless` branch elision is a third consumer of `Narrowing.predicate_certainty`,
    # and unlike `flow.always-truthy-condition` and the `&&` / `||` gate it is not constrained by the spec
    # passage above. This channel is what lets a certainty judgment tell the two apart.
    module OptimisticOrigin
      # The core-RBS annotation `RbsDispatch` reads the return type past.
      ANNOTATION = "implicitly-returns-nil"

      # The single cause carried today. Kept as a symbol (rather than a bare `true`) so a later slice can
      # distinguish further optimistic families without changing the table's shape.
      IMPLICITLY_RETURNS_NIL = :implicitly_returns_nil

      module_function

      # Whether the overload the selector actually picked carries the ignored annotation. The judgment is
      # per-overload, which is what makes it precise: `Array#first` is optimistic while `Array#first(3)` is
      # not, and `String#[]` / `Enumerable#find` are honest because they already spell the miss as `?`.
      #
      # @param method_definition [RBS::Definition::Method]
      # @param method_type [RBS::MethodType] the overload {OverloadSelector.select} returned
      # @return [Boolean]
      def optimistic_overload?(method_definition, method_type)
        type_def = matching_type_def(method_definition, method_type)
        return false unless type_def.respond_to?(:overload_annotations)

        type_def.overload_annotations.any? { |annotation| annotation.string == ANNOTATION }
      end

      # `RBS::Definition::Method#defs` runs parallel to `#method_types`, and the selector returns one of the
      # latter's elements verbatim (`ReceiverAffinity.reorder` permutes the array without copying its
      # members), so identity resolves the overload exactly. Equality is a fallback for any future path that
      # rebuilds the method type.
      def matching_type_def(method_definition, method_type)
        return nil unless method_definition.respond_to?(:defs)

        defs = method_definition.defs
        defs.find { |type_def| type_def.type.equal?(method_type) } ||
          defs.find { |type_def| type_def.type == method_type }
      end
    end
  end
end
