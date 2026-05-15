# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Inference
    # ADR-16 Tier A — engine hook. Consults every registered
    # plugin manifest's `block_as_methods` entries to decide
    # whether a block call site qualifies for `Scope#self_type`
    # narrowing.
    #
    # The match contract for a class-level DSL like Sinatra's
    # `class MyApp < Sinatra::Base; get '/foo' do ... end; end`:
    #
    # - the call's lexical receiver type is `Singleton[X]`
    #   (the implicit-self in a class body, or an explicit
    #   `MyApp.get(...)` call);
    # - the underlying class `X` equals or inherits from the
    #   entry's `receiver_constraint`;
    # - the call's method name is in the entry's `verbs`.
    #
    # On a match the helper returns the **instance** type of
    # the receiver class (`Nominal[X]`) — the narrowed
    # `self_type` for the block body, matching Sinatra's
    # runtime semantics where `Sinatra::Base#generate_method`
    # turns the block into an instance method of the user's
    # app class.
    #
    # Slice 1b ships the floor only (per ADR-16 § WD13):
    # bare-identifier method lookups inside the block resolve
    # through the inference engine's normal `self_type`-driven
    # path, so methods declared on `Sinatra::Base` (RBS or
    # otherwise) become visible. Precision additions —
    # parameter-typed block params, declared per-verb argument
    # contracts — are ceiling concerns for later slices.
    module MacroBlockSelfType
      module_function

      # @param scope         [Rigor::Scope]
      # @param call_node     [Prism::CallNode]
      # @param receiver_type [Rigor::Type, nil]
      # @return [Rigor::Type, nil] the narrowed self-type, or
      #   `nil` when no registered entry matches the call shape.
      def narrow_self_type_for(scope:, call_node:, receiver_type:)
        return nil if receiver_type.nil?

        environment = scope&.environment
        registry = environment&.plugin_registry
        return nil if registry.nil? || registry.empty?

        receiver_class_name = singleton_receiver_class_name(receiver_type)
        return nil if receiver_class_name.nil?

        verb = call_node.name
        registry.plugins.each do |plugin|
          plugin.manifest.block_as_methods.each do |entry| # rigor:disable undefined-method
            return instance_type_for(receiver_class_name, environment) if matches?(entry, verb, receiver_class_name,
                                                                                   environment)
          end
        end
        nil
      end

      # Tier A's match contract is intentionally narrow:
      # class-level DSL calls (receiver is `Singleton[X]`) only.
      # Instance-receiver calls and DSL forms whose block body
      # binds a different `self` (Concern's `included do`,
      # `instance_eval { ... }`) are handled by later slices
      # (Concern walker, Tier D, etc.) — not Tier A.
      def singleton_receiver_class_name(receiver_type)
        return nil unless receiver_type.is_a?(Type::Singleton)

        receiver_type.class_name
      end

      def matches?(entry, verb, receiver_class_name, environment)
        return false unless entry.verbs.include?(verb)

        receiver_class_inherits_from?(receiver_class_name, entry.receiver_constraint, environment)
      end

      def receiver_class_inherits_from?(class_name, constraint, environment)
        return true if class_name == constraint

        ordering = environment.class_ordering(class_name, constraint)
        %i[equal subclass].include?(ordering)
      rescue StandardError
        false
      end

      def instance_type_for(class_name, environment)
        environment.nominal_for_name(class_name) || Type::Nominal.new(class_name)
      end
    end
  end
end
