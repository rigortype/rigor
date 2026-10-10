# frozen_string_literal: true

require_relative "../../type"
require_relative "../../reflection"
require_relative "integer_step_block_params"

module Rigor
  module Inference
    module MethodDispatcher
      # The elements of the `Enumerator::ArithmeticSequence` that block-less `Integer#step` returns (issue #1794).
      #
      # `ruby/rbs` declares `class Enumerator::ArithmeticSequence < Enumerator[Numeric]`, a class with no type
      # parameter, so every element it yields reads as `Numeric` and `1.step(n, 2).map { |i| i.even? }` reported
      # `even?` on correct code. The block form's operand rule ({IntegerStepBlockParams.element_type}) decides the
      # elements here too, and the answer rides on the sequence as a Rigor-private type argument,
      # `Enumerator::ArithmeticSequence[Integer]`, which RBS has no slot for and {Type::Nominal#erase_to_rbs} drops.
      #
      # The two forms differ only past an infinite Float limit: `1.step(Float::INFINITY, 2) { … }` yields Integers
      # but the sequence yields Floats (`.first(2) #=> [1.0, 3.0]`, through `each` too). A Float limit is a
      # non-Integer operand, which the rule declines, and an untyped one answers `Dynamic[Numeric]`, so both forms
      # are sound under the shared rule.
      #
      # The type argument is read where the `Numeric` would be: a method the sequence inherits from `Enumerator`
      # or `Enumerable` (`map`, `select`, `to_a`, `first`, `each_slice`, `lazy`, …) dispatches as
      # `Enumerator[elem]`, with `self` still the sequence, and the block of the sequence's own `each` yields the
      # element. The rest of its own surface (`begin`, `end`, `last`, `step`, `size`) keeps its RBS return.
      module ArithmeticSequenceElements
        module_function

        CLASS_NAME = "Enumerator::ArithmeticSequence"
        ELEMENT_OWNERS = %w[::Enumerator ::Enumerable].freeze
        private_constant :ELEMENT_OWNERS

        # The block-less `Integer#step` return, or nil to leave the call to the RBS tier.
        def try_dispatch(context)
          return nil unless context.method_name == :step
          return nil unless context.block_type.nil?
          return nil if context.call_node.respond_to?(:block) && context.call_node.block

          element = IntegerStepBlockParams.element_type(context.receiver, context.args)
          element && Type::Combinator.nominal_of(CLASS_NAME, type_args: [element])
        end

        # The receiver `method_name` reads the sequence's element through: `Enumerator[elem]` for a method the
        # sequence inherits from `Enumerator` / `Enumerable` (and, with `block: true`, for the block of its own
        # `each`), or nil to dispatch on the receiver as it is.
        def element_receiver(receiver, method_name, environment, block: false)
          element = element_of(receiver)
          return nil if element.nil?
          return nil unless (block && method_name == :each) || inherited_element_method?(method_name, environment)

          Type::Combinator.nominal_of("Enumerator", type_args: [element])
        end

        def element_of(receiver)
          return nil unless receiver.is_a?(Type::Nominal) && receiver.class_name == CLASS_NAME
          return nil unless receiver.type_args.size == 1

          receiver.type_args.first
        end

        def inherited_element_method?(method_name, environment)
          definition = Rigor::Reflection.instance_method_definition(CLASS_NAME, method_name, environment: environment)
          return false if definition.nil?

          ELEMENT_OWNERS.include?(definition.defined_in.to_s)
        rescue StandardError
          false
        end
      end
    end
  end
end
