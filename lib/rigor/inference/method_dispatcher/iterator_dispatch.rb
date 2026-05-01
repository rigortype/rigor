# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Iterator-style block-parameter typing.
      #
      # Sits ahead of `RbsDispatch.block_param_types` so the precise
      # integer bounds for `Integer#times` / `Integer#upto` /
      # `Integer#downto` reach the block body's parameter binder.
      # Without this tier the RBS signature for `Integer#times`
      # widens the index to `Nominal[Integer]`, dropping every
      # bound the receiver carries.
      #
      # Each rule mirrors Ruby's actual iteration semantics:
      #
      # - `n.times { |i| … }` yields `i ∈ [0, n-1]` when `n > 0`,
      #   nothing otherwise. The block-param type is therefore
      #   `int<0, n-1>` for a `Constant<Integer>` receiver,
      #   `int<0, upper-1>` for a finite `IntegerRange`, and
      #   `non_negative_int` for any unbounded-above shape.
      # - `a.upto(b) { |i| … }` yields `i ∈ [a, b]` when `a <= b`.
      #   Lower bound from the receiver, upper bound from the
      #   argument.
      # - `a.downto(b) { |i| … }` yields the same domain `[b, a]`,
      #   just iterated in reverse. Lower bound from the
      #   argument, upper bound from the receiver.
      module IteratorDispatch
        module_function

        # @return [Array<Rigor::Type>, nil] block-param types, or
        #   nil to fall through to the next tier.
        def block_param_types(receiver:, method_name:, args:)
          case method_name
          when :times then times_block_params(receiver)
          when :upto  then upto_block_params(receiver, args.first)
          when :downto then downto_block_params(receiver, args.first)
          end
        end

        def times_block_params(receiver)
          return nil unless integer_rooted?(receiver)

          upper = upper_bound_of(receiver)
          return [Type::Combinator.non_negative_int] unless upper.is_a?(Integer)
          return [Type::Combinator.non_negative_int] unless upper.positive?

          [build_index_range(0, upper - 1)]
        end

        def upto_block_params(receiver, end_arg)
          return nil unless integer_rooted?(receiver) && integer_rooted?(end_arg)

          [build_index_range(lower_bound_of(receiver), upper_bound_of(end_arg))]
        end

        def downto_block_params(receiver, end_arg)
          return nil unless integer_rooted?(receiver) && integer_rooted?(end_arg)

          [build_index_range(lower_bound_of(end_arg), upper_bound_of(receiver))]
        end

        # `Constant<Integer>`, `IntegerRange`, and `Nominal[Integer]`
        # all participate. Non-integer types (Float, String, …) and
        # `Top`/`Dynamic` decline so the RBS tier answers.
        def integer_rooted?(type)
          case type
          when Type::Constant then type.value.is_a?(Integer)
          when Type::IntegerRange then true
          when Type::Nominal then type.class_name == "Integer" && type.type_args.empty?
          else false
          end
        end

        def lower_bound_of(type)
          case type
          when Type::Constant then type.value
          when Type::IntegerRange then type.min
          when Type::Nominal then Type::IntegerRange::NEG_INFINITY
          end
        end

        def upper_bound_of(type)
          case type
          when Type::Constant then type.value
          when Type::IntegerRange then type.max
          when Type::Nominal then Type::IntegerRange::POS_INFINITY
          end
        end

        # Builds a `Constant`/`IntegerRange` from possibly-symbolic
        # bounds. Vacuous ranges (lower > upper, indicating the
        # iterator does not fire) collapse to `non_negative_int` so
        # the body still type-checks against a sensible binding.
        def build_index_range(lower, upper)
          return Type::Combinator.non_negative_int if vacuous_range?(lower, upper)
          return Type::Combinator.constant_of(lower) if lower.is_a?(Integer) && lower == upper

          Type::Combinator.integer_range(lower, upper)
        end

        def vacuous_range?(lower, upper)
          return false if lower == Type::IntegerRange::NEG_INFINITY
          return false if upper == Type::IntegerRange::POS_INFINITY

          lower > upper
        end
      end
    end
  end
end
