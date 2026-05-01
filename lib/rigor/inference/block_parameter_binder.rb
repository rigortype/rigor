# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "multi_target_binder"

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
    # MultiTargetNode parameters (`|(a, b), c|`) are bound by
    # delegating each destructuring slot to
    # {Rigor::Inference::MultiTargetBinder}, so a Tuple-shaped
    # expected element type projects element-wise into the inner
    # locals (Slice 6 phase C sub-phase 2). Numbered parameters
    # (`_1`, `_2`, ...) are bound from `Prism::NumberedParametersNode`
    # using the same per-position `expected_param_types:` array, so
    # `[1, 2, 3].each { _1 + _2 }` sees `_1`/`_2` typed identically
    # to their explicit `|x, y|` counterparts.
    #
    # Block-local declarations after `;` (e.g., `|x; y, z|`) are
    # still skipped — they are explicitly block-local, so the outer
    # scope MUST NOT observe them and the binder leaves them unbound.
    #
    # See docs/internal-spec/inference-engine.md for the binding contract.
    # rubocop:disable Metrics/ClassLength
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
      #   name to bound type. Anonymous parameters are skipped;
      #   MultiTargetNode destructuring slots delegate to
      #   {MultiTargetBinder} and contribute every named local in
      #   declaration order. Numbered-parameter forms (`_1`, `_2`,
      #   ...) bind `:_1`, `:_2`, ... up to the maximum the block
      #   body refers to.
      def bind(block_node)
        params_root = block_node.parameters
        return {} if params_root.nil?

        case params_root
        when Prism::NumberedParametersNode
          bind_numbered_parameters(params_root)
        when Prism::BlockParametersNode
          bind_block_parameters(params_root)
        else
          {}
        end
      end

      private

      # `|_1, _2|` numbered-parameter form. Prism exposes the
      # implicit count through `NumberedParametersNode#maximum`
      # (the highest `_N` referenced in the body); we materialise
      # bindings for `:_1` through `:_maximum` so the block body's
      # `LocalVariableReadNode` lookups see the same types as the
      # equivalent explicit `|x, y|` form would.
      def bind_numbered_parameters(numbered_node)
        bindings = {}
        numbered_node.maximum.times do |i|
          bindings[:"_#{i + 1}"] = positional_type_at(i)
        end
        bindings
      end

      def bind_block_parameters(params_root)
        params_node = params_root.parameters
        return {} if params_node.nil?

        bindings = {}
        bind_positionals(params_node, bindings, 0)
        bind_rest(params_node, bindings)
        bind_keywords(params_node, bindings)
        bind_keyword_rest(params_node, bindings)
        bind_block_param(params_node, bindings)
        bindings
      end

      def bind_positionals(params_node, bindings, cursor)
        cursor = bind_required_positionals(params_node, bindings, cursor)
        cursor = bind_optional_positionals(params_node, bindings, cursor)
        bind_trailing_positionals(params_node, bindings, cursor)
      end

      def bind_required_positionals(params_node, bindings, cursor)
        params_node.requireds.each do |param|
          bind_required_param(param, cursor, bindings)
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
      # `|(a, b), c|` destructuring form). Slice 6 phase C sub-phase 2
      # delegates the latter to {MultiTargetBinder}, which decomposes
      # the slot's expected Tuple element-wise and binds every named
      # inner local. Other shapes (anonymous required parameters,
      # forward arguments) are silently skipped.
      def bind_required_param(param, cursor, bindings)
        case param
        when Prism::RequiredParameterNode
          bindings[param.name] = positional_type_at(cursor)
        when Prism::MultiTargetNode
          nested = MultiTargetBinder.bind(param, positional_type_at(cursor))
          bindings.merge!(nested)
        end
      end

      def positional_type_at(index)
        @expected_param_types[index] || Type::Combinator.untyped
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
