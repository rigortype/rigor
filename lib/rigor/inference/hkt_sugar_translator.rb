# frozen_string_literal: true

require "rbs"
require_relative "hkt_body"

module Rigor
  module Inference
    class HktSugarTranslator
      attr_reader :recursive

      def initialize(uri:, params_set:)
        @uri = uri
        @params_set = params_set
        @recursive = false
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def translate(type)
        case type
        when RBS::Types::Alias
          if type.name.to_s.sub(/\A::/, "") == @uri.to_s && !type.args.empty?
            @recursive = true
            args = type.args.map { |a| translate(a) }
            HktBody::AppRef.new(uri: @uri, args: args)
          else
            # Everything else degrades to a concrete leaf: HktBody has no AliasRef node and Rigor
            # resolves non-HKT aliases through RbsLoader. A bare self-reference with no type
            # arguments (`type Foo::x[T] = ... | Foo::x`) lands here too — it is malformed for a
            # parameterized alias (`rbs validate` rejects it), so it must not build an empty-args
            # `AppRef`, which `HktBody` rejects.
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

      private

      # The `else` arm and the unbound-variable / non-recursive-alias arms all degrade a subterm the
      # HKT body grammar has no node for to a concrete `Rigor::Type` leaf. `RbsTypeTranslator` has no
      # name-scope parameter — it never resolves relative names — and the alias decls this walk reads
      # come off a `resolve_type_names`-d environment, so names arrive already absolute and there is
      # nothing a scope would do here. `alias_expander: nil` is deliberate too: a nested alias reached
      # in this fallback degrades to `Dynamic[Top]` rather than pulling a second alias body into an
      # HKT definition.
      def fallback_to_type_leaf(type)
        require_relative "rbs_type_translator" unless defined?(RbsTypeTranslator)
        rigor_type = RbsTypeTranslator.translate(
          type,
          alias_expander: nil,
          type_vars: {},
          self_type: Rigor::Type::Combinator.untyped,
          instance_type: Rigor::Type::Combinator.untyped
        )
        HktBody::TypeLeaf.new(type: rigor_type)
      end
    end
  end
end
