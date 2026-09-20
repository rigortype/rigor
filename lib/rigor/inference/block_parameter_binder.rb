# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "block_auto_splat"
require_relative "multi_target_binder"

module Rigor
  module Inference
    # Builds the entry scope of a block body by translating the block's parameter list into a `name ->
    # Rigor::Type` map.
    #
    # The binder is the symmetric counterpart of {MethodParameterBinder} for `Prism::BlockNode`. The
    # expected parameter types come from the receiving method's RBS signature
    # ({Rigor::Inference::MethodDispatcher.expected_block_param_types}); parameters that the signature does
    # not cover (or that the binder cannot match by position) default to `Dynamic[Top]`. The default is the
    # Slice 1 fail-soft answer for unknown values, so a block whose receiving method has no signature still
    # binds every name into the scope (a block body whose `Local x` reads return `Dynamic[Top]` instead of
    # falling through to the unbound-local `Dynamic[Top]` event is the same observable type, but the binding
    # presence is what later slices need to attach narrowing facts to).
    #
    # MultiTargetNode parameters (`|(a, b), c|`) are bound by delegating each destructuring slot to
    # {Rigor::Inference::MultiTargetBinder}, so a Tuple-shaped expected element type projects element-wise
    # into the inner locals (Slice 6 phase C sub-phase 2). Numbered parameters (`_1`, `_2`, ...) are bound
    # from `Prism::NumberedParametersNode` as the explicit list of that many required positionals, the
    # highest `_N` the body references being the arity (CRuby's own reading: `proc { _2 }.parameters` is
    # `[[:opt, :_1], [:opt, :_2]]`, and `lambda { _2 }.arity` is 2). So `h.each { _1; _2 }` auto-splats like
    # `|k, v|`, while a body that uses only `_1` reads as `|a|` and does not (issue #1108).
    #
    # The `it` implicit parameter (Ruby 3.4+) is bound from `Prism::ItParametersNode`. It is the
    # single-argument cousin of `_1`: the binder produces `{ it: expected_param_types[0] }` so the body's
    # `Prism::ItLocalVariableReadNode` lookup sees the same type as the explicit `|x|` form would, and it
    # never auto-splats.
    #
    # A block whose parameter list CRuby splats spreads the one yielded value across its positionals;
    # {BlockAutoSplat} owns that rule and its carrier arms, and this binder only applies the table it
    # answers. Every name the spread binds from an `Array[T]` slot — and every name a nested `|(g, h)|`
    # destructure binds from one — is reported as optimistic, and {#bind_onto} records those through
    # `Scope#with_optimistic_local` exactly as the statement-level `a, b = ints` does (issue #1093; the
    # shared rule lives in {MultiTargetBinder}). A nested `|(g, h)|` destructures the one value the
    # signature already placed, so it wraps like the statement form.
    #
    # Block-local declarations after `;` (e.g., `|x; y, z|`) are still skipped — they are explicitly
    # block-local, so the outer scope MUST NOT observe them and the binder leaves them unbound.
    #
    # See docs/internal-spec/inference-engine.md for the binding contract.
    class BlockParameterBinder
      # @param expected_param_types — positional block parameter types in order. Indices
      #   the binder cannot fill from this array (because the array is shorter than the parameter list, or
      #   because the slot is a kind we do not pull from the array) default to `Dynamic[Top]`.
      def initialize(expected_param_types: [])
        @declared_param_types = expected_param_types
        reset_per_bind_state
      end

      # The names the last {#bind} bound optimistically nil-free (see the class comment).
      attr_reader :optimistic

      # Binds the block's parameters into `scope`: {#bind}'s types through `Scope#with_local`, then the
      # optimistic mark for every name in {#optimistic}.
      def bind_onto(block_node, scope)
        types = bind(block_node, scope: scope)
        MultiTargetBinder::Result.new(types: types, optimistic: @optimistic.dup.freeze).apply_to(scope)
      end

      # @return ordered map from parameter name to bound type. Anonymous
      #   parameters are skipped; MultiTargetNode destructuring slots delegate to {MultiTargetBinder} and
      #   contribute every named local in declaration order. Numbered-parameter forms (`_1`, `_2`, ...) bind
      #   `:_1`, `:_2`, ... up to the maximum the block body refers to.
      # @param scope — the scope the block is entered from, which answers a nested destructure's `to_ary`
      #   question ({MultiTargetBinder.bind_marked}).
      def bind(block_node, scope: nil)
        reset_per_bind_state
        @scope = scope
        params_root = block_node.parameters
        return {} if params_root.nil?

        case params_root
        when Prism::NumberedParametersNode
          bind_numbered_parameters(params_root)
        when Prism::ItParametersNode
          bind_it_parameter
        when Prism::BlockParametersNode
          bind_block_parameters(params_root)
        else
          {}
        end
      end

      private

      # {#apply_auto_splat} rewrites the positional table for the block it is binding, so every {#bind} starts
      # from the declared types again; a binder reused across blocks must not see the previous block's splat.
      def reset_per_bind_state
        @expected_param_types = @declared_param_types
        @splat_rest_type = nil
        @optimistic_positions = []
        @optimistic = []
        @scope = nil
      end

      # `|_1, _2|` numbered-parameter form. Prism exposes the implicit count through
      # `NumberedParametersNode#maximum` (the highest `_N` referenced in the body); we materialise bindings
      # for `:_1` through `:_maximum`, auto-splatting exactly as the explicit list of that many required
      # positionals would, so the body's `LocalVariableReadNode` lookups see the same types and marks.
      def bind_numbered_parameters(numbered_node)
        arity = numbered_node.maximum
        apply_auto_splat(BlockAutoSplat::ParameterShape.of_arity(arity))

        bindings = {}
        arity.times do |i|
          name = :"_#{i + 1}"
          bindings[name] = positional_type_at(i)
          @optimistic << name if @optimistic_positions.include?(i)
        end
        bindings
      end

      # `{ it.foo }` — Ruby 3.4 `it` is a single-argument implicit parameter. Always binds the symbol `:it`;
      # `ItLocalVariableReadNode` in the body looks the binding up by name.
      def bind_it_parameter
        { it: positional_type_at(0) }
      end

      def bind_block_parameters(params_root)
        params_node = params_root.parameters
        return {} if params_node.nil?

        apply_auto_splat(BlockAutoSplat::ParameterShape.of(params_node))

        bindings = {}
        bind_positionals(params_node, bindings, 0)
        bind_rest(params_node, bindings)
        bind_keywords(params_node, bindings)
        bind_keyword_rest(params_node, bindings)
        bind_block_param(params_node, bindings)
        bindings
      end

      # Ruby blocks (NOT lambdas) auto-splat a single yielded array-ish value when the parameter list is
      # one CRuby splats:
      #
      #   { a: 1 }.each { |k, v| ... }
      #
      # yields `[key, value]` as a single arg, but the two-param block sees `k = key, v = value`. RBS /
      # IteratorDispatch encode this as the block taking ONE `[K, V]` Tuple parameter; without this fix-up
      # the binder would assign `k = Tuple[K, V]` and `v = Dynamic[Top]`, and any call on
      # `k.<method-not-on-Tuple>` would false-fire.
      #
      # The rule fires only when the receiver yields exactly one value (`expected_param_types.size == 1`)
      # and {BlockAutoSplat} answers a table for that value and `shape`. A multi-arg yield (e.g.
      # `each_with_index`'s `(element, index)` pair) is NOT auto-splatted — matching Ruby semantics where a
      # multi-arg yield to a `|a, b, c|` block fills the extra slot with nil rather than splatting any
      # element.
      def apply_auto_splat(shape)
        return unless @expected_param_types.size == 1
        return unless shape.splats?

        table = BlockAutoSplat.for(shape, @expected_param_types[0])
        return if table.nil?

        @expected_param_types = table.types
        @optimistic_positions = table.optimistic_positions
        @splat_rest_type = table.rest_type
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
          bind_required_param(param, cursor, bindings)
          cursor += 1
        end
        cursor
      end

      # `|*rest|` binds an Array of the leftover positional arguments. The expected-types array is
      # per-position, not per-rest; we cannot reliably pick a single element type for rest, so we default to
      # `Array[Dynamic[Top]]`. Element-type precision for rest parameters is deferred (demand-gated).
      def bind_rest(params_node, bindings)
        rest = params_node.rest
        return unless rest.respond_to?(:name) && rest&.name

        bindings[rest.name] =
          @splat_rest_type || Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.untyped])
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

      # Required parameters in a block list can be either a plain `RequiredParameterNode` (named) or a
      # `MultiTargetNode` (the `|(a, b), c|` destructuring form). Slice 6 phase C sub-phase 2 delegates the
      # latter to {MultiTargetBinder}, which decomposes the slot's expected Tuple element-wise and binds
      # every named inner local. Other shapes (anonymous required parameters, forward arguments) are
      # silently skipped.
      def bind_required_param(param, cursor, bindings)
        case param
        when Prism::RequiredParameterNode
          bindings[param.name] = positional_type_at(cursor)
          @optimistic << param.name if @optimistic_positions.include?(cursor)
        when Prism::MultiTargetNode
          nested = MultiTargetBinder.bind_marked(param, positional_type_at(cursor),
                                                 optimistic: @optimistic_positions.include?(cursor), scope: @scope)
          bindings.merge!(nested.types)
          @optimistic.concat(nested.optimistic)
        end
      end

      def positional_type_at(index)
        @expected_param_types[index] || Type::Combinator.untyped
      end
    end
  end
end
