# frozen_string_literal: true

require_relative "../type"
require_relative "method_dispatcher/constant_folding"

module Rigor
  module Inference
    # Coordinates method dispatch for the inference engine.
    #
    # Given `(receiver_type, method_name, arg_types, block_type)`, the
    # dispatcher returns the inferred result type or `nil` when no rule
    # matches. `nil` is a deliberately blunt "I don't know" signal: callers
    # (today only `ExpressionTyper`) own the fail-soft fallback and decide
    # whether to record a `FallbackTracer` event.
    #
    # Slice 2 ships a single rule tier: {ConstantFolding} executes the Ruby
    # operation directly when the receiver and argument are `Constant`
    # carriers and the method is on the curated whitelist. The dispatcher's
    # public signature already reserves space for `block_type:`, RBS-backed
    # method tables (Slice 4), and ADR-2 plugin extensions (later slices),
    # so call sites added now do not have to be rewritten when those tiers
    # arrive.
    module MethodDispatcher
      module_function

      # @param receiver_type [Rigor::Type, nil] type of the receiver expression, or
      #   `nil` for an implicit-self call. Slice 2 cannot type implicit self yet,
      #   so `nil` always misses.
      # @param method_name [Symbol]
      # @param arg_types [Array<Rigor::Type>] positional argument types.
      # @param block_type [Rigor::Type, nil] reserved; ignored in Slice 2.
      # @return [Rigor::Type, nil] inferred result type, or `nil` for "no rule".
      def dispatch(receiver_type:, method_name:, arg_types:, block_type: nil) # rubocop:disable Lint/UnusedMethodArgument
        return nil if receiver_type.nil?

        ConstantFolding.try_fold(
          receiver: receiver_type,
          method_name: method_name,
          args: arg_types
        )
      end
    end
  end
end
