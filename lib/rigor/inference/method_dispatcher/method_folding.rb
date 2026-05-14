# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # `Method` (and friends) precision tier.
      #
      # Two folds make a `Method` carrier round-trip with its
      # binding visible:
      #
      # 1. **Forward** — `<receiver>.method(:sym)` (or
      #    `.method("sym")`) lifts to {Type::BoundMethod}
      #    carrying the receiver type AND the resolved Symbol.
      #    Calling with a non-literal symbol-shaped argument
      #    declines so the RBS tier still answers
      #    `Nominal[Method]`.
      # 2. **Backward** — `Type::BoundMethod#call(...)` /
      #    `#()` (Prism lowers `.()` into a CallNode whose
      #    `name` is `:call`) / `#[](...)` substitutes the
      #    bound `(receiver_type, method_name)` and recurses
      #    back into `MethodDispatcher.dispatch`. The
      #    re-entrant call lets the substituted dispatch
      #    consume every tier the original call site would
      #    have — constant folding, shape dispatch, RBS,
      #    plugin contributions, etc. The original block_type
      #    / environment / call_node / scope are threaded
      #    through unchanged so capture-sensitive tiers (the
      #    block fold) keep working.
      #
      # Lives ABOVE the standard precision-tier chain so the
      # RBS tier never sees a `BoundMethod` receiver — `Method`
      # erasure means RBS would otherwise return
      # `Method#call: (*untyped) -> untyped`, which is exactly
      # the precision loss the carrier exists to avoid.
      module MethodFolding
        module_function

        # Forward fold. Returns a {Type::BoundMethod} when the
        # call shape is `<receiver>.method(:name)` /
        # `.method("name")` with a precisely-known Symbol /
        # String argument. Declines on every other shape so
        # the RBS tier still answers `Method` for non-folding
        # cases.
        #
        # @param receiver [Rigor::Type] caller's receiver
        # @param method_name [Symbol] the method being
        #   dispatched on `receiver` — only `:method` triggers
        #   the fold.
        # @param args [Array<Rigor::Type>] caller's argument
        #   types in order. Only the single-argument case
        #   matches; other arities decline.
        def try_forward(receiver:, method_name:, args:)
          return nil unless method_name == :method
          return nil if args.size != 1

          bound_name = symbol_name_of(args.first)
          return nil if bound_name.nil?

          Type::Combinator.bound_method_of(receiver, bound_name)
        end

        # Backward fold. Recurses into `MethodDispatcher.dispatch`
        # with the bound `(receiver_type, method_name)`. The
        # `block_type` / `environment` / `call_node` / `scope`
        # are forwarded so every downstream tier (constant
        # folding, shape dispatch, plugin contributions, …)
        # keeps the original call site's context. Returns
        # `Dynamic[top]` rather than `nil` when the recursive
        # dispatch declines so the call site still ends in a
        # well-defined type (the gradual-safety net mirrors
        # the engine's "BoundMethod erases to `Method`,
        # `Method#call: (*untyped) -> untyped`" RBS fallback).
        # rubocop:disable Metrics/ParameterLists
        def try_backward(receiver:, method_name:, args:, block_type:, environment:, call_node:, scope:)
          return nil unless receiver.is_a?(Type::BoundMethod)
          return nil unless backward_method?(method_name)

          MethodDispatcher.dispatch(
            receiver_type: receiver.receiver_type,
            method_name: receiver.method_name,
            arg_types: args,
            block_type: block_type,
            environment: environment,
            call_node: call_node,
            scope: scope
          ) || Type::Combinator.untyped
        end
        # rubocop:enable Metrics/ParameterLists

        # `Method#call` / `Method#()` and `Method#[]` are the
        # invocation entry points on the `Method` API; the
        # alias `===` is also `call` semantically but is more
        # commonly used as a case-equality predicate, so we
        # do NOT fold through it (the case/when narrowing path
        # already special-cases `===` for branch typing).
        BACKWARD_METHOD_NAMES = %i[call []].freeze
        private_constant :BACKWARD_METHOD_NAMES

        def backward_method?(method_name)
          BACKWARD_METHOD_NAMES.include?(method_name)
        end

        # `Object#method` accepts both Symbol and String at
        # runtime (the latter coerced via `to_sym`). The
        # `Constant<String>` form is rare in production code
        # but cheap to support and matches Ruby's documented
        # contract.
        def symbol_name_of(arg)
          return nil unless arg.is_a?(Type::Constant)

          case arg.value
          when Symbol then arg.value
          when String then arg.value.to_sym
          end
        end
      end
    end
  end
end
