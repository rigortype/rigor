# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # `Integer#step`'s block parameter, reached through {IteratorDispatch.block_param_types} (issue #1783).
      #
      # `ruby/rbs` declares every `Numeric#step` overload with a `{ (Numeric) -> void }` block and `Integer` does
      # not redeclare `step`, so `1.step(n, 2) { |i| i.even? }` reported `even?` on correct code. The block form
      # yields Integer only while the limit and the step are Integer too: a Float step or a finite Float limit
      # makes CRuby's `ruby_float_step` yield Floats (`1.step(10, 0.5)`, `1.step(10.0)`; an infinite limit with
      # an Integer step still yields Integers, which this rule leaves on the RBS binding), and a Rational step yields
      # Rationals after the first value. So:
      #
      # - every operand provably Integer (an absent one is the Integer default; a nil limit means "no limit")
      #   binds `Integer`;
      # - an operand that is `Dynamic` (an untyped parameter, `1.step(n, 2)`) could be either, so the binding is
      #   `Dynamic[Numeric]`: Integer is unsound for `n = 0.5`, and the RBS `Numeric` reports `even?` on correct
      #   Integer code, so the answer that holds for both declines the check;
      # - anything else (a Float, a Rational, a union) falls through to the RBS `Numeric` binding, which a Float
      #   or Rational receiver also keeps.
      #
      # The keyword forms (`step(by: 2, to: 10)`, `step(10, by: 2)`) arrive as a trailing hash shape.
      module IntegerStepBlockParams
        module_function

        KEYWORD_ROLES = { to: :limit, by: :step }.freeze
        private_constant :KEYWORD_ROLES

        # @return the block-param types, or nil to fall through to the RBS tier.
        def block_param_types(receiver, args)
          return nil unless IteratorDispatch.integer_rooted?(receiver)

          operands = operands(args)
          return nil if operands.nil?

          verdicts = operands.map { |role, type| verdict(role, type) }
          return nil if verdicts.include?(:decline)
          return [Type::Combinator.nominal_of("Integer")] if verdicts.all?(:integer)

          [Type::Combinator.dynamic(Type::Combinator.nominal_of("Numeric"))]
        end

        # The `[role, type]` pairs of the call's limit and step operands, or nil when the argument list is not
        # one of `step`'s shapes.
        def operands(args)
          positional = args
          keywords = {}
          if args.last.is_a?(Type::HashShape)
            positional = args[0...-1]
            keywords = args.last.pairs
            return nil unless keywords.keys.all? { |key| KEYWORD_ROLES.key?(key) }
          end
          return nil if positional.size > 2

          pairs = positional.zip(%i[limit step]).map { |type, role| [role, type] }
          keywords.each { |key, type| pairs << [KEYWORD_ROLES.fetch(key), type] }
          pairs
        end

        def verdict(role, type)
          return :integer if IteratorDispatch.integer_rooted?(type)
          return :integer if role == :limit && type.is_a?(Type::Constant) && type.value.nil?
          return :unknown if type.is_a?(Type::Dynamic)

          :decline
        end
      end
    end
  end
end
