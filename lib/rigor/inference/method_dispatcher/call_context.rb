# frozen_string_literal: true

module Rigor
  module Inference
    module MethodDispatcher
      # Immutable value object carrying everything a dispatch tier needs to fold a single call site. Built
      # once per `MethodDispatcher.dispatch` and threaded — unchanged — through every tier, replacing the
      # `(receiver:, method_name:, args:, …)` keyword quartet that each tier used to redeclare (several
      # needing a Metrics/ParameterLists rubocop exemption).
      #
      # Every tier satisfies one interface — `try_dispatch(CallContext) -> Rigor::Type?` (the `_DispatchTier`
      # RBS interface). Pure tiers (the singleton folders, ConstantFolding, ShapeDispatch, …) read only
      # `receiver` / `method_name` / `args` and ignore the rest; the RBS / backward / block-param tiers
      # consult the wider context.
      #
      # Derived call sites (the user-class fallback's `public_only` RBS retry, the Tier-B origin-module
      # redispatch) use `Data#with` to copy the base context with the few fields that differ rather than
      # rebuilding the quartet by hand.
      #
      # Fields:
      # - `receiver`            — the receiver `Rigor::Type` (nil short-circuits)
      # - `method_name`         — the called selector (Symbol)
      # - `args`                — positional argument `Rigor::Type`s
      # - `block_type`          — the block's `Rigor::Type`, or nil
      # - `environment`         — the analysis `Environment` (RBS loader, …)
      # - `call_node`           — the Prism call node, when available
      # - `scope`               — the enclosing `Scope` (discovered methods, …)
      # - `self_type_override`  — receiver to attribute private dispatch to
      # - `public_only`         — suppress private-method resolution (explicit, non-self receiver)
      CallContext = Data.define(
        :receiver, :method_name, :args,
        :block_type, :environment, :call_node, :scope,
        :self_type_override, :public_only
      ) do
        # Keyword factory with nil/false defaults for the optional context fields, so a caller that only has
        # the call quartet (the common precise-tier path) need not spell out the rest.
        #
        # This is the single place the call-context field list is enumerated — the whole point of the value
        # object is to absorb the wide keyword list the tiers used to each redeclare.
        def self.build(receiver:, method_name:, args:, # rubocop:disable Metrics/ParameterLists
                       block_type: nil, environment: nil, call_node: nil,
                       scope: nil, self_type_override: nil, public_only: false)
          # Positional `new` (field-definition order) avoids the keyword hash a `new(receiver:, …)` call
          # allocates — this runs once per dispatch and was a top allocation site. Order MUST track the
          # `Data.define` field list above.
          new(
            receiver, method_name, args,
            block_type, environment, call_node, scope,
            self_type_override, public_only
          )
        end
      end
    end
  end
end
