# frozen_string_literal: true

require_relative "../../type"
require_relative "call_context"
require_relative "iterator_dispatch"

module Rigor
  module Inference
    module MethodDispatcher
      # Symbol-form `reduce` / `inject` return-type tier.
      #
      # `IteratorDispatch.inject_block_params` deliberately declines the
      # Symbol-call shapes (`(1..n).reduce(1, :*)`, `[1,2,3].reduce(:+)`)
      # because they carry no block to bind parameters for — the decline
      # of *block-param typing* is correct. What that decline leaves on
      # the floor is the *return type*: with no block and no precise tier,
      # the call falls to `Enumerable#reduce`'s RBS overload
      # `(untyped, Symbol) -> untyped`, so the whole fold widens to
      # `Dynamic[top]`.
      #
      # This tier recovers a precise return type for the Symbol-operand
      # forms by dispatching the named operator on the accumulated type:
      #
      # - `(seed, :op)` (2-arg) — operand starts at the seed type `S`;
      #   the result type is `dispatch(:op, widen(S) ∪ widen(E), widen(E))`
      #   joined with the seed (the seed is returned unchanged when the
      #   collection is empty). `E` is the receiver's element type.
      # - `(:op)` (1-arg) — no seed: the first element seeds the memo, so
      #   the operand type is `E` and the result is
      #   `dispatch(:op, widen(E), widen(E))`. RBS models this overload as
      #   `() { (E, E) -> E } -> E` (no nil), so the tier returns the
      #   operator result without manufacturing a nil — staying consistent
      #   with the declared type and Rigor's false-positive discipline
      #   (the empty-collection `nil` runtime case is not modelled by RBS
      #   and adding it here would only pressure callers into defensive
      #   nil-handling for code that works).
      #
      # The tier is precision-additive: it declines (returns nil, today's
      # `Dynamic[top]` behaviour) for every shape it cannot prove —
      # unknown element type, Dynamic / Top receiver, a non-`Constant`
      # Symbol operand, or an operator the engine cannot dispatch on the
      # widened operand types.
      #
      # `widen_value_pinned` (ADR-55/56) collapses `Constant`/`IntegerRange`
      # operands to their nominal base before dispatch so the result is the
      # operator's nominal return (`Integer`) rather than a constant-folded
      # `Constant[120]` — full constant folding of the reduction is out of
      # scope, the precision target is the carrier (`Integer`), not the value.
      module ReduceFolding
        module_function

        REDUCE_METHODS = %i[reduce inject].freeze
        private_constant :REDUCE_METHODS

        # @return [Rigor::Type, nil]
        def try_dispatch(context)
          return nil unless REDUCE_METHODS.include?(context.method_name)
          return nil if context.block_type

          args = context.args
          operator, seed = operator_and_seed(args)
          return nil if operator.nil?

          element = IteratorDispatch.element_type_of(context.receiver)
          return nil if element.nil?

          fold_result(operator, seed, element, context.environment)
        end

        # Splits the call's positional arguments into the operator Symbol
        # and the optional seed. Returns `[nil, nil]` for any non-Symbol-
        # operand shape so `try_dispatch` declines.
        #
        # - `[:op]`          -> operator `:op`, no seed
        # - `[seed, :op]`    -> operator `:op`, seed `seed`
        def operator_and_seed(args)
          case args.size
          when 1
            sym = symbol_value(args[0])
            sym ? [sym, nil] : [nil, nil]
          when 2
            sym = symbol_value(args[1])
            sym ? [sym, args[0]] : [nil, nil]
          else
            [nil, nil]
          end
        end

        def symbol_value(type)
          return nil unless type.is_a?(Type::Constant)

          type.value.is_a?(Symbol) ? type.value : nil
        end

        # Dispatches the operator on the widened operand types. With a
        # seed the memo type spans `seed | element` (the first iteration's
        # memo is the seed, every later iteration's memo is a previous
        # operator result); without a seed the memo and operand are both
        # the element type.
        def fold_result(operator, seed, element, environment)
          widened_element = Type::Combinator.widen_value_pinned(element)
          memo = if seed.nil?
                   widened_element
                 else
                   Type::Combinator.union(
                     Type::Combinator.widen_value_pinned(seed), widened_element
                   )
                 end

          result = dispatch_operator(memo, operator, widened_element, environment)
          return nil if result.nil?

          # The seed itself is the result when the collection is empty
          # (`[].reduce(s, :op) == s`), so a 2-arg fold's static type is
          # the operator result joined with the seed. The seed is widened
          # (`Constant[0]` -> `Integer`) for the join so the carrier stays
          # the precision target rather than leaking a value-pinned member
          # (`0 | Integer`) — full constant folding of the fold is out of
          # scope.
          return result if seed.nil?

          Type::Combinator.union(Type::Combinator.widen_value_pinned(seed), result)
        end

        def dispatch_operator(memo, operator, operand, environment)
          MethodDispatcher.dispatch(
            receiver_type: memo, method_name: operator,
            arg_types: [operand], environment: environment
          )
        end
      end
    end
  end
end
