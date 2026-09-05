# frozen_string_literal: true

require_relative "../../type"
require_relative "call_context"
require_relative "iterator_dispatch"

module Rigor
  module Inference
    module MethodDispatcher
      # Symbol-form `reduce` / `inject` return-type tier.
      #
      # `IteratorDispatch.inject_block_params` deliberately declines the Symbol-call shapes
      # (`(1..n).reduce(1, :*)`, `[1,2,3].reduce(:+)`) because they carry no block to bind parameters for —
      # the decline of *block-param typing* is correct. What that decline leaves on the floor is the
      # *return type*: with no block and no precise tier, the call falls to `Enumerable#reduce`'s RBS
      # overload `(untyped, Symbol) -> untyped`, so the whole fold widens to `Dynamic[top]`.
      #
      # This tier recovers a precise return type for the Symbol-operand forms by dispatching the named
      # operator on the accumulated type:
      #
      # - `(seed, :op)` (2-arg) — operand starts at the seed type `S`; the result type is
      #   `dispatch(:op, widen(S) ∪ widen(E), widen(E))` joined with the seed (the seed is returned
      #   unchanged when the collection is empty). `E` is the receiver's element type.
      # - `(:op)` (1-arg) — no seed: the first element seeds the memo, so the operand type is `E` and the
      #   result is `dispatch(:op, widen(E), widen(E))`. RBS models this overload as
      #   `() { (E, E) -> E } -> E` (no nil), so the tier returns the operator result without manufacturing
      #   a nil — staying consistent with the declared type and Rigor's false-positive discipline (the
      #   empty-collection `nil` runtime case is not modelled by RBS and adding it here would only pressure
      #   callers into defensive nil-handling for code that works).
      #
      # The tier is precision-additive: it declines (returns nil, today's `Dynamic[top]` behaviour) for
      # every shape it cannot prove — unknown element type, Dynamic / Top receiver, a non-`Constant` Symbol
      # operand, or an operator the engine cannot dispatch on the widened operand types.
      #
      # `widen_value_pinned` (ADR-55/56) collapses `Constant`/`IntegerRange` operands to their nominal base
      # before dispatch so the result is the operator's nominal return (`Integer`) rather than a
      # constant-folded `Constant[120]` — full constant folding of the reduction is out of scope, the
      # precision target is the carrier (`Integer`), not the value.
      module ReduceFolding
        module_function

        REDUCE_METHODS = %i[reduce inject].freeze
        private_constant :REDUCE_METHODS

        # Allow-listed pure, side-effect-free fold operators. Each is safe on the foldable constant operand
        # classes (Integer / Float / Rational); division / modulo by zero is caught by the rescue harness
        # in `execute_constant_reduce` and declines to the nominal fold. `:gcd` / `:lcm` are valid binary
        # Integer methods (`acc.public_send(:gcd, elem)`); `:min` / `:max` are *not* (no
        # `Integer#min`/`#max` — they would raise and decline), so they are deliberately omitted.
        CONSTANT_FOLD_OPERATORS = %i[+ * - / % & | ^ gcd lcm].freeze
        private_constant :CONSTANT_FOLD_OPERATORS

        # Hard caps (ADR-41 WD4 style). The element count is checked BEFORE the receiver is enumerated, so
        # a `(1..1_000_000)` range never materialises. The bit-length cap rejects factorial-style blow-up
        # (`(1..64).reduce(:*)` is a ~296-bit Integer) so the folded value can never become an
        # analyzer-heavy bignum.
        CONSTANT_FOLD_ELEMENT_CAP = 64
        CONSTANT_FOLD_BIT_CAP = 256
        private_constant :CONSTANT_FOLD_ELEMENT_CAP, :CONSTANT_FOLD_BIT_CAP

        # @rbs return: Rigor::Type?
        def try_dispatch(context)
          return nil unless REDUCE_METHODS.include?(context.method_name)
          return nil if context.block_type

          args = context.args
          operator, seed = operator_and_seed(args)
          return nil if operator.nil?

          # Precision pre-check: when the receiver is a fully-constant collection (a `Constant[Range]` with
          # foldable endpoints or a `Tuple` of `Constant` elements) and the operator is an allow-listed pure
          # op, treat the reduction as a pure function and execute it on the real values, capped. Any
          # decline (size cap, non-constant member, magnitude, exception) falls through to the
          # carrier-precise nominal fold below — byte-identical to pre-fold behaviour.
          folded = try_constant_reduce(context.receiver, operator, seed)
          return folded if folded

          element = IteratorDispatch.element_type_of(context.receiver)
          return nil if element.nil?

          fold_result(operator, seed, element, context.environment)
        end

        # Executes the reduction on real constant values, or returns nil to decline. The caller falls
        # through to the nominal fold on a nil return, so every guard here is precision-additive only.
        #
        # @rbs seed: Rigor::Type? --
        #   The optional seed type; only a foldable `Constant` seed is honoured, any other seed declines.
        # @rbs return: Rigor::Type::Constant?
        def try_constant_reduce(receiver, operator, seed)
          return nil unless CONSTANT_FOLD_OPERATORS.include?(operator)

          members = constant_members(receiver)
          return nil if members.nil?

          seed_value, seed_present = constant_seed(seed)
          return nil if !seed.nil? && !seed_present

          execute_constant_reduce(members, operator, seed_value, seed_present)
        end

        # Extracts the receiver's elements as a Ruby Array of foldable constant values, or nil to decline.
        # Checks the size cap BEFORE enumerating so an unbounded / huge `Constant[Range]` (e.g.
        # `(1..1_000_000)`) never calls `to_a`.
        #
        # @rbs return: Array[untyped]?
        def constant_members(receiver)
          case receiver
          when Type::Constant
            constant_range_members(receiver.value)
          when Type::Tuple
            tuple_members(receiver.elements)
          end
        end

        def constant_range_members(value)
          return nil unless value.is_a?(Range)

          first = value.begin
          last = value.end
          return nil unless foldable?(first) && foldable?(last)
          # Reject endless / beginless ranges (`(1..)`, `(..5)`).
          return nil if first.nil? || last.nil?

          # Size BEFORE enumeration — `Range#size` is O(1) for numeric ranges and never materialises the
          # elements.
          size = value.size
          return nil unless size.is_a?(Integer)
          return nil if size > CONSTANT_FOLD_ELEMENT_CAP

          value.to_a
        rescue StandardError
          nil
        end

        def tuple_members(elements)
          return nil if elements.size > CONSTANT_FOLD_ELEMENT_CAP
          return nil unless elements.all? { |e| e.is_a?(Type::Constant) && foldable?(e.value) }

          elements.map(&:value)
        end

        # @rbs return: [untyped, bool] --
        #   `[seed_value, present?]`. A nil seed type yields `[nil, false]` (no-seed form). A foldable `Constant` seed
        #   yields `[value, true]`. Any other seed yields `[nil, false]` so the caller can decline.
        def constant_seed(seed)
          return [nil, false] if seed.nil?
          return [nil, false] unless seed.is_a?(Type::Constant) && foldable?(seed.value)

          [seed.value, true]
        end

        # Runs the actual reduction, guarded by the rescue harness and the magnitude cap. Empty-collection
        # semantics match Ruby: `[].reduce(s, :op) == s` (seed form) and `[].reduce(:op) == nil` (no-seed
        # form → declines so the nominal fold's no-nil contract stands; see `fold_result`).
        #
        # @rbs return: Rigor::Type::Constant?
        def execute_constant_reduce(members, operator, seed_value, seed_present)
          result =
            if seed_present
              members.reduce(seed_value) { |acc, e| acc.public_send(operator, e) }
            else
              # No-seed empty collection reduces to nil; decline so the nominal no-nil contract is preserved
              # rather than folding to `Constant[nil]`.
              return nil if members.empty?

              members.reduce { |acc, e| acc.public_send(operator, e) }
            end

          return nil unless foldable?(result)
          return nil if magnitude_too_large?(result)

          Type::Combinator.constant_of(result)
        rescue StandardError
          # Division by zero, type mismatch, or any operator error: decline.
          nil
        end

        FOLDABLE_FOLD_CLASSES = [Integer, Float, Rational].freeze
        private_constant :FOLDABLE_FOLD_CLASSES

        def foldable?(value)
          FOLDABLE_FOLD_CLASSES.any? { |klass| value.is_a?(klass) }
        end

        # Rejects bignum blow-up. A folded Integer wider than the bit cap (factorial, repeated
        # multiplication) declines to the nominal `Integer` carrier rather than parking a heavy literal in
        # the type graph. Float / Rational carry no comparable blow-up risk.
        def magnitude_too_large?(result)
          result.is_a?(Integer) && result.bit_length > CONSTANT_FOLD_BIT_CAP
        end

        # Splits the call's positional arguments into the operator Symbol and the optional seed. Returns
        # `[nil, nil]` for any non-Symbol-operand shape so `try_dispatch` declines.
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

        # Dispatches the operator on the widened operand types. With a seed the memo type spans
        # `seed | element` (the first iteration's memo is the seed, every later iteration's memo is a
        # previous operator result); without a seed the memo and operand are both the element type.
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

          # The seed itself is the result when the collection is empty (`[].reduce(s, :op) == s`), so a
          # 2-arg fold's static type is the operator result joined with the seed. The seed is widened
          # (`Constant[0]` -> `Integer`) for the join so the carrier stays the precision target rather than
          # leaking a value-pinned member (`0 | Integer`) — full constant folding of the fold is out of
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
