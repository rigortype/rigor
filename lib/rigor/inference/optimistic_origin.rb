# frozen_string_literal: true

require "prism"

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
    # Issue #286: the `if` / `unless` branch elision is one consumer of `Narrowing.predicate_certainty`; the
    # other two are `flow.always-truthy-condition` and the `&&` / `||` `constant_value_polarity` gate, and the
    # spec passage above binds all three. This channel is what lets a certainty judgment tell the two apart.
    #
    # Issue #313: the mark is attached to a *value* — the call node that produced it, or the local / ivar it
    # was bound to — but every one of those consumers reads a *predicate expression*, and a predicate is
    # rarely the bare carrier. `x.nil?` collapses the carrier's nil-freeness into a `Constant[false]` of its
    # own, `!x.nil?` inverts it, and `x.nil? || y.nil?` composes two of them; each step produced an unmarked
    # `Constant` that the gates then read as proof. {.resolve} therefore derives the mark through exactly
    # those shapes, so the exclusion survives composition instead of stopping at the read.
    module OptimisticOrigin
      # The core-RBS annotation `RbsDispatch` reads the return type past.
      ANNOTATION = "implicitly-returns-nil"

      # The single cause carried today. Kept as a symbol (rather than a bare `true`) so a later slice can
      # distinguish further optimistic families without changing the table's shape.
      IMPLICITLY_RETURNS_NIL = :implicitly_returns_nil

      # The argument-free unary predicates whose folded result is a statement about the receiver's
      # *nil-freeness* and nothing else, which is what makes the derivation sound rather than a general taint:
      # `nil?` answers the exact question the optimism is a bet on, and `!` (which Prism spells as a `CallNode`
      # named `:!`, covering both `!x` and `not x`) inverts whatever it is applied to. Value predicates —
      # `empty?`, `zero?`, `any?` — are deliberately absent: they fold from the carrier's *value*, and marking
      # them would widen this channel into a taint that silences genuine diagnostics.
      NIL_COLLAPSING_PREDICATES = %i[nil? !].freeze

      module_function

      # The effective optimistic-nil-free cause of an expression under `scope`, or nil when its nil-freeness is
      # a property of the value rather than a bet. The single owner of the judgment: `ExpressionTyper`,
      # `StatementEvaluator` and `AlwaysTruthyConditionCollector` all route here, so the three consumers the
      # spec binds cannot drift apart.
      #
      # Resolution order — the mark recorded on the node itself, then the binding a bare local / ivar read (or
      # a write in value position, `if (x = MAP[k])`) resolves through, then the predicate-fold derivation
      # issue #313 added.
      #
      # @param node [Prism::Node, nil]
      # @param scope [Rigor::Scope, nil]
      # @return [Symbol, nil]
      def resolve(node, scope)
        return nil if node.nil? || scope.nil?

        recorded = scope.optimistic_origins[node]
        return recorded if recorded

        case node
        when Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode then scope.optimistic_local(node.name)
        when Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode then scope.optimistic_ivar(node.name)
        when Prism::AndNode, Prism::OrNode then resolve(node.left, scope) || resolve(node.right, scope)
        when Prism::CallNode then resolve_through_predicate(node, scope)
        when Prism::ParenthesesNode then resolve_through_parentheses(node, scope)
        end
      end

      # `recv.nil?` / `!recv` — the fold is a statement about `recv`, so it is exactly as optimistic as `recv`
      # is. A block or any argument means this is not the unary predicate it looks like (`x.!(y)` is a
      # user-defined operator), and the derivation declines.
      def resolve_through_predicate(node, scope)
        return nil unless NIL_COLLAPSING_PREDICATES.include?(node.name)
        return nil unless node.block.nil?
        return nil unless node.arguments.nil? || node.arguments.arguments.empty?

        resolve(node.receiver, scope)
      end

      # `(x.nil?)` — a single-statement parenthesised body is its own value, and authors do parenthesise a
      # composed guard. A multi-statement body's value is its last statement, but the earlier statements can
      # rebind, so only the single-statement form is derived.
      def resolve_through_parentheses(node, scope)
        body = node.body
        return nil unless body.is_a?(Prism::StatementsNode) && body.body.size == 1

        resolve(body.body.first, scope)
      end

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
