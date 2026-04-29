# frozen_string_literal: true

require_relative "../type"
require_relative "method_dispatcher/constant_folding"
require_relative "method_dispatcher/shape_dispatch"
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
    # 2. {ShapeDispatch}: returns the precise element/value type for a
    #    curated catalogue of `Tuple`/`HashShape` element-access
    #    methods (`first`, `last`, `[]` with a static integer/key,
    #    `fetch`, `dig`, `size`/`length`/`count`). Slice 5 phase 2.
    # 3. {RbsDispatch}: looks up the receiver's class in the RBS
    #    environment carried by the scope and translates the method's
    #    return type into a Rigor::Type. Slice 4.
    #
    # `ShapeDispatch` deliberately runs *above* {RbsDispatch} so the
    # precise per-position/per-key answer wins over the projected
    # `Array#[]`/`Hash#fetch` answer; it falls through (`nil`) when
    # the call cannot be proved against the static shape, in which
    # case the projection answer from {RbsDispatch} applies.
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
      # @param block_type [Rigor::Type, nil] inferred return type of the
      #   accompanying `do ... end` / `{ ... }` block (Slice 6 phase C
      #   sub-phase 2). When non-nil, the dispatcher prefers an
      #   overload that declares a block, and binds the method's
      #   block-return type variable to `block_type` so a return type
      #   like `Array[U]` resolves to `Array[block_type]`.
      # @param environment [Rigor::Environment, nil] required for
      #   RBS-backed dispatch; when nil only constant folding can fire.
      # @return [Rigor::Type, nil] inferred result type, or `nil` for "no rule".
      def dispatch(receiver_type:, method_name:, arg_types:, block_type: nil, environment: nil)
        return nil if receiver_type.nil?

        constant_result = ConstantFolding.try_fold(
          receiver: receiver_type,
          method_name: method_name,
          args: arg_types
        )
        return constant_result if constant_result

        shape_result = ShapeDispatch.try_dispatch(
          receiver: receiver_type,
          method_name: method_name,
          args: arg_types
        )
        return shape_result if shape_result

        RbsDispatch.try_dispatch(
          receiver: receiver_type,
          method_name: method_name,
          args: arg_types,
          environment: environment,
          block_type: block_type
        )
      end

      # Returns the positional block parameter types declared by the
      # receiving method's selected RBS overload, translated into
      # `Rigor::Type`. Used by the StatementEvaluator's CallNode
      # handler to bind block parameter names before evaluating the
      # block body.
      #
      # The probe is best-effort: it returns an empty array whenever
      # the receiver, environment, method definition, or selected
      # overload does not provide statically declared block parameter
      # types. Callers MUST treat the empty array as "no information";
      # the binder falls back to `Dynamic[Top]` for every parameter
      # slot in that case.
      #
      # @param receiver_type [Rigor::Type, nil]
      # @param method_name [Symbol]
      # @param arg_types [Array<Rigor::Type>]
      # @param environment [Rigor::Environment, nil]
      # @return [Array<Rigor::Type>]
      def expected_block_param_types(receiver_type:, method_name:, arg_types:, environment: nil)
        return [] if receiver_type.nil?

        RbsDispatch.block_param_types(
          receiver: receiver_type,
          method_name: method_name,
          args: arg_types,
          environment: environment
        )
      end
    end
  end
end
