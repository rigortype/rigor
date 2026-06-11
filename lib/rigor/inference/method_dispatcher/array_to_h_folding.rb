# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # `Array#to_h { |x| [k, v] }` (and the no-block-pair tuple form's
      # block sibling) return-type fold.
      #
      # `Enumerable#to_h` with a block maps every element to a
      # `[key, value]` pair and collects them into a Hash. When the
      # block's inferred return type is a recognizable 2-element
      # `Tuple` (`[K, V]`), this tier projects the pair into a
      # `Hash[K, V]` nominal whose key/value parameters are the
      # widened pair types. Without this fold the call hits the RBS
      # generic and the block's `[K, V]` return is dropped, typing as
      # `Hash[Dynamic[top], Dynamic[top]]`.
      #
      # Value-pinned constants in the pair (`Constant[2]`) are widened
      # to their nominal (`Integer`) for the Hash parameters: the built
      # hash holds many keys, so pinning the parameter to a single
      # element's literal would be unsound for the aggregate. The same
      # widening the loop-body fixpoint applies (`Combinator#
      # widen_value_pinned`) is reused.
      #
      # Declines (returns `nil`, leaving today's RBS answer) when:
      #
      # - there is no block at the call site,
      # - the block return type is not a 2-element `Tuple`, or
      # - the receiver is not an Array-shaped carrier (`Tuple` or
      #   `Array` nominal). Hash receivers keep their existing
      #   `ShapeDispatch#hash_to_h` identity fold.
      module ArrayToHFolding
        module_function

        def try_dispatch(context)
          return nil unless context.method_name == :to_h

          block_type = context.block_type
          return nil unless block_type.is_a?(Type::Tuple)
          return nil unless block_type.elements.size == 2
          return nil unless array_shaped?(context.receiver)

          key = Type::Combinator.widen_value_pinned(block_type.elements[0])
          value = Type::Combinator.widen_value_pinned(block_type.elements[1])
          Type::Combinator.nominal_of("Hash", type_args: [key, value])
        end

        def array_shaped?(receiver)
          case receiver
          when Type::Tuple then true
          when Type::Nominal then receiver.class_name == "Array"
          else false
          end
        end
      end
    end
  end
end
