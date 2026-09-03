# frozen_string_literal: true

require "rbs"
require_relative "hkt_body"

module Rigor
  module Inference
    class HktSugarTranslator
      class << self
        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        def translate(rbs_type, uri:, params_set:, name_scope:)
          new(uri: uri, params_set: params_set, name_scope: name_scope).translate(rbs_type)
        end
      end

      attr_reader :recursive

      def initialize(uri:, params_set:, name_scope:)
        @uri = uri
        @params_set = params_set
        @name_scope = name_scope
        @recursive = false
      end

      def translate(type)
        case type
        when RBS::Types::Alias
          if type.name.to_s.sub(/\A::/, "") == @uri.to_s
            @recursive = true
            args = type.args.map { |a| translate(a) }
            HktBody::AppRef.new(uri: @uri, args: args)
          else
            # Re-wrap other aliases as NominalApp or TypeLeaf?
            # Actually, we can just translate them to TypeLeaf if they have no args,
            # but Rigor handles aliases via RbsLoader.
            # If we don't expand them here, they will just be RbsTypeTranslator.translate'd later?
            # Wait, HktBody doesn't have an AliasRef node. HktBody uses NominalApp for things with args,
            # or TypeLeaf for concrete Rigor::Type.

            # Since Rigor doesn't support generic aliases outside of HKT AppRef,
            # we can just translate to TypeLeaf.
            fallback_to_type_leaf(type)
          end
        when RBS::Types::ClassInstance
          class_name = type.name.to_s.sub(/\A::/, "")
          if type.args.empty?
            HktBody::TypeLeaf.new(type: Rigor::Type::Nominal.new(class_name))
          else
            args = type.args.map { |a| translate(a) }
            HktBody::NominalApp.new(class_name: class_name, args: args)
          end
        when RBS::Types::Variable
          if @params_set.include?(type.name)
            HktBody::Param.new(name: type.name)
          else
            fallback_to_type_leaf(type)
          end
        when RBS::Types::Union
          HktBody::Union.new(arms: type.types.map { |t| translate(t) })
        when RBS::Types::Optional
          HktBody::Union.new(arms: [
                               translate(type.type),
                               HktBody::TypeLeaf.new(type: Rigor::Type::Constant.new(nil))
                             ])
        when RBS::Types::Bases::Nil
          HktBody::TypeLeaf.new(type: Rigor::Type::Constant.new(nil))
        when RBS::Types::Bases::Bool
          HktBody::TypeLeaf.new(type: Rigor::Type::Combinator.union(Rigor::Type::Constant.new(true), Rigor::Type::Constant.new(false)))
        when RBS::Types::Bases::Any
          HktBody::TypeLeaf.new(type: Rigor::Type::Combinator.untyped)
        else
          fallback_to_type_leaf(type)
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      private

      def fallback_to_type_leaf(type)
        require_relative "rbs_type_translator" unless defined?(RbsTypeTranslator)
        rigor_type = RbsTypeTranslator.translate(
          type,
          alias_expander: nil,
          type_vars: {},
          name_scope: @name_scope,
          self_type: Rigor::Type::Combinator.untyped,
          instance_type: Rigor::Type::Combinator.untyped
        )
        HktBody::TypeLeaf.new(type: rigor_type)
      end
    end
  end
end
