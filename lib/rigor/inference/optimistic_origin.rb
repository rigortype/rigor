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

      # Issue #1094 — the binary comparisons that are the same statement as `nil?` when one operand is the `nil`
      # literal: `x == nil`, `nil != x`, `x.equal?(nil)`, `nil === x`. Every one folds from the other operand's
      # nil-freeness alone, so the derivation is exactly as sound as the unary one. A comparison against any
      # other value folds from the carrier's value and stays out, for the reason the value predicates do.
      NIL_COMPARISONS = %i[== != eql? equal? ===].freeze

      # {.miss_answer}'s answer for an expression whose value on a miss cannot be told.
      UNKNOWN_MISS = Object.new.freeze

      # Issue #1302 — a local / ivar mark that also records what the bound value answers on a miss, so
      # {.miss_answer} reads a predicate through the binding as it reads the inline form. `Scope` stores it in
      # the mark table in place of the bare cause, so the answer is kept and dropped with the mark itself; a
      # binding whose miss answer cannot be told stores the bare cause, as before.
      BoundMark = Data.define(:cause, :miss)

      # The marks a binding of today's single cause records, interned so that marking `v = h[k]` allocates
      # nothing beyond the table it always rebuilt.
      INTERNED_BOUND_MARKS = [nil, true, false].to_h do |miss|
        [miss, BoundMark.new(cause: IMPLICITLY_RETURNS_NIL, miss: miss)]
      end.freeze
      private_constant :INTERNED_BOUND_MARKS

      module_function

      # What `Scope` stores for a binding marked with `cause` whose value answers `miss` on a miss.
      def bound_mark(cause, miss)
        return cause if miss.equal?(UNKNOWN_MISS)

        (cause == IMPLICITLY_RETURNS_NIL && INTERNED_BOUND_MARKS[miss]) || BoundMark.new(cause: cause, miss: miss)
      end

      # The cause and the recorded miss answer of an entry {.bound_mark} made (or nil for no entry).
      def bound_cause(mark) = mark.is_a?(BoundMark) ? mark.cause : mark
      def bound_miss(mark) = mark.is_a?(BoundMark) ? mark.miss : UNKNOWN_MISS

      # The entry a control-flow join keeps for a name both arms mark: the answer survives only when the arms
      # agree on it, since otherwise a miss can take either arm's.
      def join_bound_marks(mine, theirs) = mine == theirs ? mine : bound_cause(mine)

      # `rebound` — `scope` with the local `name` rebound to its type across a loop's iterations
      # (`CapturedLocals.bind`) — re-marked with the mark `scope` holds for `name` or `optimistic`, the one an
      # iteration's own rebind made. `scope`'s recorded miss answer is kept unless an iteration's mark joins it:
      # that one comes without its answer, so the pair's cannot be told.
      def carry_local_mark(scope, rebound, name, optimistic)
        miss = optimistic ? UNKNOWN_MISS : scope.optimistic_local_miss(name)
        rebound.with_optimistic_local(name, scope.optimistic_local(name) || optimistic, miss: miss)
      end

      # {.carry_local_mark} for an instance variable.
      def carry_ivar_mark(scope, rebound, name, optimistic)
        miss = optimistic ? UNKNOWN_MISS : scope.optimistic_ivar_miss(name)
        rebound.with_optimistic_ivar(name, scope.optimistic_ivar(name) || optimistic, miss: miss)
      end

      # The effective optimistic-nil-free cause of an expression under `scope`, or nil when its nil-freeness is
      # a property of the value rather than a bet. The single owner of the judgment: `ExpressionTyper`,
      # `StatementEvaluator` and `AlwaysTruthyConditionCollector` all route here, so the three consumers the
      # spec binds cannot drift apart.
      #
      # Resolution order — the mark recorded on the node itself, then the binding a bare local / ivar read (or
      # a write in value position, `if (x = MAP[k])`) resolves through, then a safe-navigation call and the
      # predicate-fold derivation issue #313 added.
      def resolve(node, scope)
        return nil if node.nil? || scope.nil?

        recorded = scope.optimistic_origins[node]
        return recorded if recorded

        case node
        when Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode then scope.optimistic_local(node.name)
        when Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode then scope.optimistic_ivar(node.name)
        when Prism::AndNode, Prism::OrNode then resolve(node.left, scope) || resolve(node.right, scope)
        when Prism::CallNode then resolve_through_safe_navigation(node, scope) || resolve_through_predicate(node, scope)
        when Prism::ParenthesesNode then resolve_through_parentheses(node, scope)
        end
      end

      # `recv&.m` is `nil` exactly when `recv` is (or when `m` answers `nil`), so it restates `recv`'s presence
      # and is as optimistic as `recv`. Only the call carrying the `&.` is derived: Ruby skips that one call and
      # no more, so `recv&.m.n` sends `n` to the `nil` and raises (or answers `NilClass#n`), and neither it nor
      # a plain read `recv.m` produces the `nil` a miss would — their own nil-freeness rests on the method's
      # answer. A nil-collapsing predicate over the call (`recv&.m.nil?`) still resolves, through
      # {.resolve_through_predicate} and back here.
      def resolve_through_safe_navigation(node, scope)
        resolve(node.receiver, scope) if node.safe_navigation?
      end

      # `recv.nil?` / `!recv` / `recv == nil` — the fold is a statement about `recv`, so it is exactly as
      # optimistic as `recv` is.
      def resolve_through_predicate(node, scope)
        operand = nil_question_operand(node)
        operand && resolve(operand, scope)
      end

      # The operand a nil-collapsing predicate restates the nil-ness of, or nil when `node` is not one. A block
      # or any argument means `nil?` / `!` is not the unary predicate it looks like (`x.!(y)` is a user-defined
      # operator). A comparison needs exactly one positional argument and exactly one `nil` literal side, and
      # answers the other side (`nil == nil` states nothing about a carrier).
      def nil_question_operand(node)
        return nil unless node.block.nil?

        arguments = node.arguments&.arguments || []
        if NIL_COLLAPSING_PREDICATES.include?(node.name)
          node.receiver if arguments.empty?
        elsif NIL_COMPARISONS.include?(node.name) && arguments.size == 1
          nil_comparison_operand(node.receiver, arguments.first)
        end
      end

      def nil_comparison_operand(receiver, argument)
        if argument.is_a?(Prism::NilNode) && !receiver.nil? && !receiver.is_a?(Prism::NilNode)
          receiver
        elsif receiver.is_a?(Prism::NilNode) && !argument.is_a?(Prism::NilNode)
          argument
        end
      end

      # What a marked expression answers when the carrier its mark rests on misses, or {UNKNOWN_MISS}. The
      # carrier itself — the read the mark is recorded on, or a `recv&.m` over a marked receiver — answers `nil`,
      # and each nil-collapsing predicate over it answers what it answers for that value: `!` its negation,
      # `nil?` / `== nil` whether it is `nil`, `!= nil` the reverse. A local / ivar read answers what its binding
      # recorded beside the mark ({BoundMark}, issue #1302): `nil` for `x = h[k]` and for `x = recv&.m?`. An
      # `&&` / `||`, a binding that recorded nothing, and anything else is unknown. `ExpressionTyper` widens a
      # predicate's folded boolean only when the miss answers the other boolean (or cannot be told), so
      # `!recv&.empty?` — `!false` on a hit, `!nil` on a miss — stays `true`, and so does `x = recv&.empty?; !x`.
      def miss_answer(node, scope)
        return nil if scope.optimistic_origins[node]

        case node
        when Prism::LocalVariableReadNode then scope.optimistic_local_miss(node.name)
        when Prism::InstanceVariableReadNode then scope.optimistic_ivar_miss(node.name)
        when Prism::CallNode then miss_answer_of_call(node, scope)
        when Prism::ParenthesesNode
          body = node.body
          body.is_a?(Prism::StatementsNode) && body.body.size == 1 ? miss_answer(body.body.first, scope) : UNKNOWN_MISS
        else UNKNOWN_MISS
        end
      end

      def miss_answer_of_call(node, scope)
        return nil if node.safe_navigation? && resolve(node.receiver, scope)

        operand = nil_question_operand(node)
        inner = operand ? miss_answer(operand, scope) : UNKNOWN_MISS
        return UNKNOWN_MISS if inner.equal?(UNKNOWN_MISS)

        case node.name
        when :! then !inner
        when :!= then !inner.nil?
        else inner.nil?
        end
      end

      # `(x.nil?)` — a single-statement parenthesised body is its own value, and authors do parenthesise a
      # composed guard. A multi-statement body's value is its last statement, but the earlier statements can
      # rebind, so only the single-statement form is derived.
      def resolve_through_parentheses(node, scope)
        body = node.body
        return nil unless body.is_a?(Prism::StatementsNode) && body.body.size == 1

        resolve(body.body.first, scope)
      end

      # The mark a multiple assignment's right-hand side hands to the slots it fills, in the shape
      # `MultiTargetBinder.bind_marked`'s `optimistic:` takes. `true` when the whole right-hand side resolves
      # to a mark: a miss makes it `nil`, and `k, v = nil` binds `nil` to every fixed slot, so each slot's
      # nil-freeness is the same bet (the rule a nested target under an optimistic slot already follows). A
      # literal array right-hand side (`x, y = h[k], 1`) is judged element-wise instead — an Array of each
      # element's own marks, nested for a nested literal — since each element is its slot's value; a splat
      # element makes the slot positions unknowable and declines. `false` when nothing is marked.
      def destructuring_marks(node, scope)
        return true if resolve(node, scope)
        return false unless node.is_a?(Prism::ArrayNode) && node.elements.none?(Prism::SplatNode)

        marks = node.elements.map { |element| destructuring_marks(element, scope) }
        marks.any? { |mark| mark != false } ? marks : false
      end

      # Issue #1302 — the miss answer every slot {.destructuring_marks} marks records: `nil` when each marked
      # part of the right-hand side answers `nil` on a miss, since `nil` destructures to `nil` in every slot, and
      # {UNKNOWN_MISS} otherwise. A marked right-hand side a miss makes a boolean (`a, b = !h[k]`) binds it to
      # the first slot only, so its slots are not told apart and all of them record nothing.
      def destructuring_miss(node, scope)
        return miss_answer(node, scope).nil? ? nil : UNKNOWN_MISS if resolve(node, scope)
        return nil unless node.is_a?(Prism::ArrayNode)

        node.elements.all? { |element| destructuring_miss(element, scope).nil? } ? nil : UNKNOWN_MISS
      end

      # Whether the overload the selector actually picked carries the ignored annotation. The judgment is
      # per-overload, which is what makes it precise: `Array#first` is optimistic while `Array#first(3)` is
      # not, and `String#[]` / `Enumerable#find` are honest because they already spell the miss as `?`.
      #
      # @param method_type — the overload {OverloadSelector.select} returned
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
