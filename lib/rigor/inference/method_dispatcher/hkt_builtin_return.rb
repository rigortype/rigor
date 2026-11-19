# frozen_string_literal: true

require_relative "../../type"
require_relative "../../builtins/hkt_builtins"

module Rigor
  module Inference
    module MethodDispatcher
      # The HKT-builtin return tier (ADR-20 slice 3): the stdlib methods whose upstream RBS return is `untyped` and
      # whose runtime shape Rigor models as a Lightweight HKT (`JSON.parse` as `json::value`). The table is
      # `Rigor::Builtins::HktBuiltins::METHOD_RETURN_OVERRIDES`. Its place in the order is `MethodDispatcher`'s
      # `BUNDLED_OVERRIDE_TIERS`.
      module HktBuiltinReturn
        module_function

        # ADR-20 slice 3 — looks up the receiver / method pair in
        # {Rigor::Builtins::HktBuiltins::METHOD_RETURN_OVERRIDES} and returns the reduced HKT type.
        # Only fires when the receiver is a {Rigor::Type::Singleton} (the `JSON.parse` shape) and
        # the registry-backed reduction succeeds; returns `nil` otherwise so the dispatcher falls
        # through to RBS.
        def try_dispatch(context)
          receiver_type = context.receiver
          method_name = context.method_name
          arg_types = context.args
          environment = context.environment
          return nil if environment.nil?
          return nil unless receiver_type.is_a?(Type::Singleton)

          Rigor::Builtins::HktBuiltins.method_return_override(
            class_name: receiver_type.class_name,
            method_name: method_name,
            kind: :singleton,
            arg_types: arg_types,
            hkt_registry: environment.hkt_registry
          )
        end
      end
    end
  end
end
