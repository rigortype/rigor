# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    module CheckRules
      # ADR-67 WD6b — the shared "is this node rooted at an inferred parameter?" predicate.
      #
      # When the `parameter_inference:` gate seeds an undeclared parameter from its call-site union, that type
      # is a *lower bound* (only the resolved call sites contribute; an unseen / dynamic caller could pass any
      # wider value). A diagnostic decided against a lower bound is a false positive by construction — the same
      # reasoning that keeps ADR-67 WD1 non-negotiable at the parameter boundary. So every negative in-body
      # rule must decline when the value it reasons about is (transitively) an inferred parameter.
      #
      # `rooted?` walks a receiver / argument / condition-subject node down to its syntactic root and reports
      # whether that root is a pristine inferred-parameter local. It is purely syntactic — a bounded AST walk
      # over `.receiver` — not a value-flow provenance channel (the mark stays on the direct parameter local
      # in the scope; this reads the chain root at the firing site). It covers:
      #
      # - the direct receiver / subject: `param.foo`, `case param`
      # - an indexed element: `param[i] - x` (the `-` receiver is the `[]` call whose root is `param`)
      # - any method chain: `param.foo.bar`, `param.foo(arg).baz`, `param.key?(:x)`
      # - an array or hash literal holding the parameter (issue #2189): `[param].first.upcase`,
      #   `{a: param}[:a].upcase`. The engine reads such an element back precisely, so the read is the
      #   parameter's lower bound again; any other call on the literal declines too, the FP-safe direction.
      # - an instance variable the same method wrote from such a value (issue #2189): `@x = param; @x.upcase`.
      #   This one IS a scope mark — {Inference::StatementEvaluator#eval_ivar_write} stamps `:inferred_param`
      #   under the ivar's `@`-prefixed name, which no local can spell — because the write and the read are
      #   separate statements. The mark is method-local: the class-ivar census that seeds a sibling method's
      #   ivars types the write's RHS without the inference seed, so a cross-method read is not a lower bound.
      # - `Array(param)` (issue #2280): the conversion passes the parameter's elements through, so
      #   `Array(param).first.upcase` reads the lower bound back.
      # - an `if` / `unless` / ternary whose value is the parameter (issue #2280): `(c ? param : param).upcase`.
      #   Unlike `&&` / `||`, a branch that does not hold the parameter keeps its diagnostic: the form is rooted
      #   when every branch that can run is. A predicate the engine folds to one arm (the same certainty
      #   `StatementEvaluator#eval_if` elides the dead arm on) leaves only that arm to decide, so
      #   `(c ? param : 1).upcase` declines when `c` folds truthy and reports `Integer` when it folds falsey.
      #
      # Every value derived from an inferred parameter by dispatch is itself a lower bound, so firing against it
      # is an FP by the same construction. No-op on a normal `check` run — `Scope#inferred_param?` is false
      # unless the gate seeded the table.
      module InferredParamGuard
        module_function

        # A defensive depth cap against a pathological receiver chain (the walk is otherwise linear in chain
        # length, which is tiny in practice).
        MAX_DEPTH = 64

        def rooted?(node, scope, depth = 0)
          return false if node.nil? || depth > MAX_DEPTH

          case node
          when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then scope.inferred_param?(node.name)
          when Prism::CallNode then call_rooted?(node, scope, depth + 1)
          when Prism::ArrayNode, Prism::HashNode, Prism::KeywordHashNode, Prism::AssocNode
            literal_rooted?(node, scope, depth + 1)
          else combining_rooted?(node, scope, depth + 1)
          end
        end

        def call_rooted?(node, scope, depth)
          return rooted?(node.receiver, scope, depth) unless array_conversion?(node)

          rooted?(node.arguments.arguments.first, scope, depth)
        end

        # A receiverless `Array(x)` — Kernel#Array with exactly one plain argument and no block.
        def array_conversion?(node)
          node.receiver.nil? && node.name == :Array && node.block.nil? &&
            node.arguments&.arguments&.size == 1
        end

        # An array or hash literal is rooted when any element is: the engine reads the element back precisely.
        def literal_rooted?(node, scope, depth)
          parts = node.is_a?(Prism::AssocNode) ? [node.key, node.value] : node.elements
          parts.any? { |part| rooted?(part, scope, depth) }
        end

        # Value-combining forms: the produced value is a union of the operands, so it is a lower bound when ANY
        # operand is inferred-parameter-rooted (`cps[i] - x rescue -1`, `a && param.foo`, `param || b`). Declining
        # on the whole expression is FP-safe by the same lower-bound argument.
        def combining_rooted?(node, scope, depth)
          case node
          when Prism::RescueModifierNode
            rooted?(node.expression, scope, depth) || rooted?(node.rescue_expression, scope, depth)
          when Prism::AndNode, Prism::OrNode then rooted?(node.left, scope, depth) || rooted?(node.right, scope, depth)
          when Prism::ParenthesesNode then rooted?(last_statement(node.body), scope, depth)
          when Prism::StatementsNode then rooted?(node.body.last, scope, depth)
          when Prism::IfNode, Prism::UnlessNode then conditional_rooted?(node, scope, depth)
          when Prism::ElseNode then rooted?(node.statements, scope, depth)
          else false
          end
        end

        # Every branch that can run must be rooted; an absent branch is `nil`, never rooted. The predicate is
        # typed only when the branches disagree, so a conditional that never mentions a parameter costs nothing.
        def conditional_rooted?(node, scope, depth)
          when_truthy, when_falsey = node.is_a?(Prism::IfNode) ? [node.statements, node.subsequent] : [node.else_clause, node.statements]
          truthy_rooted = rooted?(when_truthy, scope, depth)
          falsey_rooted = rooted?(when_falsey, scope, depth)
          return truthy_rooted if truthy_rooted == falsey_rooted

          case predicate_certainty(node.predicate, scope)
          when :truthy then truthy_rooted
          when :falsey then falsey_rooted
          else false
          end
        end

        # The arm certainty `StatementEvaluator#branch_certainty` elides on: a decidable version guard, else the
        # predicate's folded truthiness unless an optimistic carrier props it up.
        def predicate_certainty(predicate, scope)
          guard = Inference::VersionGuard.verdict(predicate)
          return guard if guard
          return nil unless Inference::OptimisticOrigin.resolve(predicate, scope).nil?

          Inference::Narrowing.predicate_certainty(scope.type_of(predicate))
        end

        def last_statement(body)
          body.is_a?(Prism::StatementsNode) ? body.body.last : body
        end
      end
    end
  end
end
