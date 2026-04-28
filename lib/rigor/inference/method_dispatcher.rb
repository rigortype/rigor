# frozen_string_literal: true

require_relative "../type"
require_relative "method_dispatcher/constant_folding"
require_relative "method_dispatcher/rbs_dispatch"

module Rigor
  module Inference
    # Coordinates method dispatch for the inference engine.
    #
    # Given `(receiver_type, method_name, arg_types, block_type, environment)`,
    # the dispatcher returns the inferred result type or `nil` when no
    # rule matches. `nil` is a deliberately blunt "I don't know" signal:
    # callers (today only `ExpressionTyper`) own the fail-soft fallback
    # and decide whether to record a `FallbackTracer` event.
    #
    # Tiers (in order):
    #
    # 1. {ConstantFolding}: executes the Ruby operation directly when
    #    the receiver and argument are `Constant` carriers and the
    #    method is on the curated whitelist. Slice 2.
    # 2. {RbsDispatch}: looks up the receiver's class in the RBS
    #    environment carried by the scope and translates the method's
    #    return type into a Rigor::Type. Slice 4.
    #
    # The dispatcher's public signature reserves space for `block_type:`
    # and ADR-2 plugin extensions (later slices), so call sites added
    # now do not have to be rewritten when those tiers arrive.
    module MethodDispatcher
      module_function

      # @param receiver_type [Rigor::Type, nil] type of the receiver expression, or
      #   `nil` for an implicit-self call.
      # @param method_name [Symbol]
      # @param arg_types [Array<Rigor::Type>] positional argument types.
      # @param block_type [Rigor::Type, nil] reserved; ignored in Slice 4
      #   phase 1.
      # @param environment [Rigor::Environment, nil] required for
      #   RBS-backed dispatch; when nil only constant folding can fire.
      # @return [Rigor::Type, nil] inferred result type, or `nil` for "no rule".
      # rubocop:disable Lint/UnusedMethodArgument
      def dispatch(receiver_type:, method_name:, arg_types:, block_type: nil, environment: nil)
        return nil if receiver_type.nil?

        constant_result = ConstantFolding.try_fold(
          receiver: receiver_type,
          method_name: method_name,
          args: arg_types
        )
        return constant_result if constant_result

        RbsDispatch.try_dispatch(
          receiver: receiver_type,
          method_name: method_name,
          args: arg_types,
          environment: environment
        )
      end
      # rubocop:enable Lint/UnusedMethodArgument
    end
  end
end
