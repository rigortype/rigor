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
      # redispatch) use `#with` to copy the base context with the few fields that differ rather than
      # rebuilding the quartet by hand.
      #
      # A plain class that freezes itself, not a `Data` (ADR-116 WD12): `Data.new` turns positional arguments
      # into a keyword Hash before it calls `initialize`, so a `build` allocated three objects where this
      # class allocates one, once per dispatch. What a `Data` gave and callers use is kept — the readers,
      # `with`, value equality and frozen instances; `to_h`, `members` and `deconstruct_keys` had no caller
      # and are gone.
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
      class CallContext
        attr_reader :receiver, :method_name, :args,
                    :block_type, :environment, :call_node, :scope,
                    :self_type_override, :public_only

        # The field names, for `with` to check its keywords against.
        FIELDS = %i[
          receiver method_name args block_type environment call_node scope self_type_override public_only
        ].freeze
        private_constant :FIELDS

        # Keyword factory with nil/false defaults for the optional context fields, so a caller that only has
        # the call quartet (the common precise-tier path) need not spell out the rest.
        #
        # This is the single place a caller enumerates the call-context field list — the whole point of the
        # value object is to absorb the wide keyword list the tiers used to each redeclare.
        def self.build(receiver:, method_name:, args:, # rubocop:disable Metrics/ParameterLists
                       block_type: nil, environment: nil, call_node: nil,
                       scope: nil, self_type_override: nil, public_only: false)
          # This runs once per dispatch and was a top allocation site, so the fields go to `new` positionally:
          # nothing but the context itself is allocated. Order MUST track `initialize`.
          new(
            receiver, method_name, args,
            block_type, environment, call_node, scope,
            self_type_override, public_only
          )
        end

        # Positional, in the order of the field list above.
        def initialize(receiver, method_name, args, # rubocop:disable Metrics/ParameterLists
                       block_type, environment, call_node, scope,
                       self_type_override, public_only)
          @receiver = receiver
          @method_name = method_name
          @args = args
          @block_type = block_type
          @environment = environment
          @call_node = call_node
          @scope = scope
          @self_type_override = self_type_override
          @public_only = public_only
          freeze
        end

        # `dup` skips `initialize`, so the copy is frozen here, as a `Data`'s copy is.
        def initialize_copy(source)
          super
          freeze
        end

        # A fresh context with the named fields replaced. It takes any keyword and raises `ArgumentError` for
        # one that names no field, as `Data#with` did.
        def with(**changes)
          changes.each_key do |name|
            raise ArgumentError, "unknown keyword: #{name.inspect}" unless FIELDS.include?(name)
          end

          self.class.new(
            changes.fetch(:receiver, @receiver), changes.fetch(:method_name, @method_name),
            changes.fetch(:args, @args), changes.fetch(:block_type, @block_type),
            changes.fetch(:environment, @environment), changes.fetch(:call_node, @call_node),
            changes.fetch(:scope, @scope), changes.fetch(:self_type_override, @self_type_override),
            changes.fetch(:public_only, @public_only)
          )
        end

        # Two contexts of the same class are equal when every field is.
        def ==(other)
          other.instance_of?(self.class) && fields == other.fields
        end

        def eql?(other)
          other.instance_of?(self.class) && fields.eql?(other.fields)
        end

        # Seeded with the class, as `eql?` compares it.
        def hash
          [self.class, fields].hash
        end

        protected

        def fields
          [@receiver, @method_name, @args, @block_type, @environment, @call_node, @scope, @self_type_override,
           @public_only]
        end
      end
    end
  end
end
