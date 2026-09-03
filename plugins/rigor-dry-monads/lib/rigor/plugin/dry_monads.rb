# frozen_string_literal: true

require "rigor/plugin"
require "rigor/inference/hkt_registry"
require "rigor/inference/hkt_body_parser"

module Rigor
  module Plugin
    # rigor-dry-monads — Tier A plugin for dry-monads Result and Maybe carriers per
    # [ADR-20](../../../../../docs/adr/20-lightweight-hkt.md) Slice 4.
    class DryMonads < Rigor::Plugin::Base
      RESULT_REGISTRATION = Inference::HktRegistry::Registration.new(
        uri: :"dry_monads::result",
        arity: 2,
        variance: %i[out out],
        bound: Type::Combinator.result_of(Type::Combinator.untyped, Type::Combinator.untyped)
      )

      MAYBE_REGISTRATION = Inference::HktRegistry::Registration.new(
        uri: :"dry_monads::maybe",
        arity: 1,
        variance: %i[out],
        bound: Type::Combinator.maybe_of(Type::Combinator.untyped)
      )

      RESULT_DEFINITION = Inference::HktRegistry.definition_with_body_tree(
        uri: :"dry_monads::result",
        params: %i[T E],
        body_tree: Inference::HktBodyParser.parse("Result[T, E]", params: %i[T E]),
        source_path: __FILE__,
        source_line: __LINE__
      )

      MAYBE_DEFINITION = Inference::HktRegistry.definition_with_body_tree(
        uri: :"dry_monads::maybe",
        params: %i[T],
        body_tree: Inference::HktBodyParser.parse("Maybe[T]", params: %i[T]),
        source_path: __FILE__,
        source_line: __LINE__
      )

      CONSTRUCTOR_METHODS = %i[Success Failure Some None].freeze
      UNWRAP_METHODS = %i[value! failure value_or].freeze

      manifest(
        id: "dry-monads",
        version: "0.1.0",
        description: "Lightweight HKT support for dry-monads Result and Maybe carriers",
        hkt_registrations: [RESULT_REGISTRATION, MAYBE_REGISTRATION],
        hkt_definitions: [RESULT_DEFINITION, MAYBE_DEFINITION]
      )

      dynamic_return methods: -> { CONSTRUCTOR_METHODS } do |call_node, scope|
        args = call_node.arguments&.arguments || []
        case call_node.name
        when :Success
          val = args.first ? scope.type_of(args.first) : Type::Combinator.untyped
          Type::Combinator.result_of(val, Type::Combinator.bot)
        when :Failure
          err = args.first ? scope.type_of(args.first) : Type::Combinator.untyped
          Type::Combinator.result_of(Type::Combinator.bot, err)
        when :Some
          val = args.first ? scope.type_of(args.first) : Type::Combinator.untyped
          Type::Combinator.maybe_of(val)
        when :None
          Type::Combinator.maybe_of(Type::Combinator.bot)
        end
      end

      dynamic_return receivers: %w[Dry::Monads::Result Dry::Monads::Maybe Result Maybe],
                     methods: -> { UNWRAP_METHODS } do |call_node, scope|
        receiver = call_node.receiver
        next nil if receiver.nil?

        rec_type = scope.type_of(receiver)
        args = call_node.arguments&.arguments || []
        case call_node.name
        when :value!
          if rec_type.is_a?(Type::Result)
            rec_type.ok_type
          elsif rec_type.is_a?(Type::Maybe)
            rec_type.value_type
          end
        when :failure
          rec_type.err_type if rec_type.is_a?(Type::Result)
        when :value_or
          fallback = args.first ? scope.type_of(args.first) : Type::Combinator.untyped
          if rec_type.is_a?(Type::Result)
            Type::Combinator.union(rec_type.ok_type, fallback)
          elsif rec_type.is_a?(Type::Maybe)
            Type::Combinator.union(rec_type.value_type, fallback)
          end
        end
      end
    end

    Rigor::Plugin.register(DryMonads)
  end
end
