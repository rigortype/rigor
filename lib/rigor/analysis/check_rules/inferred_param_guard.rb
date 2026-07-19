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
          when Prism::LocalVariableReadNode then scope.inferred_param?(node.name)
          when Prism::CallNode then rooted?(node.receiver, scope, depth + 1)
          # Value-combining forms: the produced value is a union of the operands, so it is a lower bound when
          # ANY operand is inferred-parameter-rooted (`cps[i] - x rescue -1`, `a && param.foo`, `param || b`).
          # Declining on the whole expression is FP-safe by the same lower-bound argument.
          when Prism::RescueModifierNode
            rooted?(node.expression, scope, depth + 1) || rooted?(node.rescue_expression, scope, depth + 1)
          when Prism::AndNode, Prism::OrNode
            rooted?(node.left, scope, depth + 1) || rooted?(node.right, scope, depth + 1)
          when Prism::ParenthesesNode then rooted?(last_statement(node.body), scope, depth + 1)
          when Prism::StatementsNode then rooted?(node.body.last, scope, depth + 1)
          else false
          end
        end

        def last_statement(body)
          body.is_a?(Prism::StatementsNode) ? body.body.last : body
        end
      end
    end
  end
end
