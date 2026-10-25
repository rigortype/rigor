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

        # `fold` is whether `scope` is still the scope the walked node is evaluated in. The callers pass the scope
        # at the start of the expression; once the walk passes something evaluated earlier inside it (a leading
        # statement, the left operand of `&&`, an earlier literal element, a conditional's predicate), that
        # earlier code may have rebound what a nested predicate reads (`(c = false; c ? param : 1)`), so a
        # conditional below no longer folds its predicate in `scope`.
        def rooted?(node, scope, depth = 0, fold: true)
          return false if node.nil? || depth > MAX_DEPTH

          case node
          when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then scope.inferred_param?(node.name)
          when Prism::CallNode then call_rooted?(node, scope, depth + 1, fold)
          when Prism::ArrayNode, Prism::HashNode, Prism::KeywordHashNode, Prism::AssocNode
            literal_rooted?(node, scope, depth + 1, fold)
          else combining_rooted?(node, scope, depth + 1, fold)
          end
        end

        def call_rooted?(node, scope, depth, fold)
          return rooted?(node.receiver, scope, depth, fold: fold) unless array_conversion?(node, scope)

          rooted?(node.arguments.arguments.first, scope, depth, fold: fold)
        end

        # A receiverless `Array(x)` reaching Kernel#Array: exactly one plain argument, no block, and no project
        # `Array` on `self`'s class or its project ancestors to bind ahead of Kernel's.
        def array_conversion?(node, scope)
          node.receiver.nil? && node.name == :Array && node.block.nil? &&
            node.arguments&.arguments&.size == 1 && !project_array_method?(scope)
        end

        def project_array_method?(scope)
          self_type = scope.self_type
          case self_type
          when Type::Nominal then scope.discovered_method_through_ancestors?(self_type.class_name, :Array, :instance)
          when Type::Singleton
            scope.discovered_method_through_ancestors?(self_type.class_name, :Array, :singleton)
          else false
          end
        end

        # An array or hash literal is rooted when any element is: the engine reads the element back precisely.
        def literal_rooted?(node, scope, depth, fold)
          parts = node.is_a?(Prism::AssocNode) ? [node.key, node.value] : node.elements
          parts.each_with_index.any? { |part, index| rooted?(part, scope, depth, fold: fold && index.zero?) }
        end

        # Value-combining forms: the produced value is a union of the operands, so it is a lower bound when ANY
        # operand is inferred-parameter-rooted (`cps[i] - x rescue -1`, `a && param.foo`, `param || b`). Declining
        # on the whole expression is FP-safe by the same lower-bound argument.
        def combining_rooted?(node, scope, depth, fold)
          case node
          when Prism::RescueModifierNode
            rooted?(node.expression, scope, depth, fold: fold) ||
              rooted?(node.rescue_expression, scope, depth, fold: false)
          when Prism::AndNode, Prism::OrNode
            rooted?(node.left, scope, depth, fold: fold) || rooted?(node.right, scope, depth, fold: false)
          when Prism::ParenthesesNode then body_rooted?(node.body, scope, depth, fold)
          when Prism::StatementsNode then body_rooted?(node, scope, depth, fold)
          when Prism::IfNode, Prism::UnlessNode then conditional_rooted?(node, scope, depth, fold)
          when Prism::ElseNode then rooted?(node.statements, scope, depth, fold: fold)
          else false
          end
        end

        # A body's value is its last statement; any statement before it runs first.
        def body_rooted?(body, scope, depth, fold)
          return rooted?(body, scope, depth, fold: fold) unless body.is_a?(Prism::StatementsNode)

          rooted?(body.body.last, scope, depth, fold: fold && body.body.size == 1)
        end

        # Every branch that can run must be rooted; an absent branch is `nil`, never rooted. The predicate is
        # typed only when the branches disagree, so a conditional that never mentions a parameter costs nothing.
        # An arm runs after the predicate, so a conditional nested in one never folds.
        def conditional_rooted?(node, scope, depth, fold)
          truthy_rooted, falsey_rooted = arms(node).map { |arm| rooted?(arm, scope, depth, fold: false) }
          return truthy_rooted if truthy_rooted == falsey_rooted
          return false unless fold

          case predicate_certainty(node.predicate, scope)
          when :truthy then truthy_rooted
          when :falsey then falsey_rooted
          else false
          end
        end

        # `[runs when the predicate is truthy, runs when it is falsey]`.
        def arms(node)
          node.is_a?(Prism::IfNode) ? [node.statements, node.subsequent] : [node.else_clause, node.statements]
        end

        # The arm certainty `StatementEvaluator#branch_certainty` elides on: a decidable version guard, else the
        # predicate's folded truthiness unless an optimistic carrier props it up.
        def predicate_certainty(predicate, scope)
          guard = Inference::VersionGuard.verdict(predicate)
          return guard if guard
          return nil unless Inference::OptimisticOrigin.resolve(predicate, scope).nil?

          Inference::Narrowing.predicate_certainty(scope.type_of(predicate))
        end
      end
    end
  end
end
