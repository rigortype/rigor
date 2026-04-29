# frozen_string_literal: true

require "prism"

require_relative "../type"

module Rigor
  module Inference
    # Builds the entry scope of a block body by translating the block's
    # parameter list into a `name -> Rigor::Type` map.
    #
    # The binder is the symmetric counterpart of {MethodParameterBinder}
    # for `Prism::BlockNode`. The expected parameter types come from
    # the receiving method's RBS signature
    # ({Rigor::Inference::MethodDispatcher.expected_block_param_types});
    # parameters that the signature does not cover (or that the binder
    # cannot match by position) default to `Dynamic[Top]`. The default
    # is the Slice 1 fail-soft answer for unknown values, so a block
    # whose receiving method has no signature still binds every name
    # into the scope (a block body whose `Local x` reads return
    # `Dynamic[Top]` instead of falling through to the unbound-local
    # `Dynamic[Top]` event is the same observable type, but the
    # binding presence is what later slices need to attach narrowing
    # facts to).
    #
    # MultiTargetNode parameters (`|(a, b), c|`) are deferred to a
    # follow-up: the binder skips them entirely so the surrounding
    # block body still type-checks under the outer scope. Block-local
    # declarations after `;` (e.g., `|x; y, z|`) are also skipped --
    # they are explicitly block-local, so the outer scope MUST NOT
    # observe them and the binder leaves them unbound.
    #
    # See docs/internal-spec/inference-engine.md for the binding contract.
    class BlockParameterBinder
      # @param expected_param_types [Array<Rigor::Type>] positional block
      #   parameter types in order. Indices the binder cannot fill from
      #   this array (because the array is shorter than the parameter
      #   list, or because the slot is a kind we do not pull from the
      #   array) default to `Dynamic[Top]`.
      def initialize(expected_param_types: [])
        @expected_param_types = expected_param_types
      end

      # @param block_node [Prism::BlockNode]
      # @return [Hash{Symbol => Rigor::Type}] ordered map from parameter
      #   name to bound type. Anonymous parameters and MultiTargetNode
      #   destructuring slots are skipped.
      def bind(block_node)
        params_root = block_node.parameters
        return {} if params_root.nil?

        params_node = block_parameters_for(params_root)
        return {} if params_node.nil?

        bindings = {}
        bind_positionals(params_node, bindings, 0)
        bind_rest(params_node, bindings)
        bind_keywords(params_node, bindings)
        bind_keyword_rest(params_node, bindings)
        bind_block_param(params_node, bindings)
        bindings
      end

      private

      # `BlockNode#parameters` is normally a `BlockParametersNode` whose
      # `parameters` field is a `ParametersNode` (the same shape as a
      # method's parameter list). Numbered-block forms expose a
      # `NumberedParametersNode` directly; we treat those as having
      # no named locals to bind (the body still uses `_1`/`_2`/... but
      # those reads are surfaced as `LocalVariableReadNode` only
      # implicitly and are not handled in this slice).
      def block_parameters_for(params_root)
        return nil unless params_root.is_a?(Prism::BlockParametersNode)

        params_root.parameters
      end

      def bind_positionals(params_node, bindings, cursor)
        cursor = bind_required_positionals(params_node, bindings, cursor)
        cursor = bind_optional_positionals(params_node, bindings, cursor)
        bind_trailing_positionals(params_node, bindings, cursor)
      end

      def bind_required_positionals(params_node, bindings, cursor)
        params_node.requireds.each do |param|
          name = required_name(param)
          bindings[name] = positional_type_at(cursor) if name
          cursor += 1
        end
        cursor
      end

      def bind_optional_positionals(params_node, bindings, cursor)
        params_node.optionals.each do |param|
          bindings[param.name] = positional_type_at(cursor) if param.respond_to?(:name) && param.name
          cursor += 1
        end
        cursor
      end

      def bind_trailing_positionals(params_node, bindings, cursor)
        params_node.posts.each do |param|
          name = required_name(param)
          bindings[name] = positional_type_at(cursor) if name
          cursor += 1
        end
        cursor
      end

      # `|*rest|` binds an Array of the leftover positional arguments.
      # The expected-types array is per-position, not per-rest; we
      # cannot reliably pick a single element type for rest, so we
      # default to `Array[Dynamic[Top]]`. Slice C sub-phase 2 may
      # tighten this when the receiving method's RBS rest type is
      # available.
      def bind_rest(params_node, bindings)
        rest = params_node.rest
        return unless rest.respond_to?(:name) && rest&.name

        bindings[rest.name] = Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.untyped])
      end

      def bind_keywords(params_node, bindings)
        params_node.keywords.each do |kw|
          case kw
          when Prism::RequiredKeywordParameterNode, Prism::OptionalKeywordParameterNode
            bindings[kw.name] = Type::Combinator.untyped
          end
        end
      end

      def bind_keyword_rest(params_node, bindings)
        kw_rest = params_node.keyword_rest
        return unless kw_rest.respond_to?(:name) && kw_rest&.name

        symbol_nominal = Type::Combinator.nominal_of("Symbol")
        bindings[kw_rest.name] = Type::Combinator.nominal_of(
          "Hash",
          type_args: [symbol_nominal, Type::Combinator.untyped]
        )
      end

      def bind_block_param(params_node, bindings)
        block = params_node.block
        return unless block.respond_to?(:name) && block&.name

        bindings[block.name] = Type::Combinator.nominal_of(Proc)
      end

      # Required parameters in a block list can be either a plain
      # `RequiredParameterNode` (named) or a `MultiTargetNode` (the
      # `|(a, b), c|` destructuring form). The latter has no top-level
      # name to bind, so the binder skips it; sub-phase 2 will recurse
      # into the targets and bind each component.
      def required_name(param)
        return param.name if param.is_a?(Prism::RequiredParameterNode)

        nil
      end

      def positional_type_at(index)
        @expected_param_types[index] || Type::Combinator.untyped
      end
    end
  end
end
