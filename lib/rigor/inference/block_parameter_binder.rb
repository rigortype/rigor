# frozen_string_literal: true

require "prism"

require_relative "../type"
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
    # from `Prism::NumberedParametersNode` using the same per-position `expected_param_types:` array, so
    # `[1, 2, 3].each { _1 + _2 }` sees `_1`/`_2` typed identically to their explicit `|x, y|` counterparts.
    #
    # The `it` implicit parameter (Ruby 3.4+) is bound from `Prism::ItParametersNode`. It is the
    # single-argument cousin of `_1`: the binder produces `{ it: expected_param_types[0] }` so the body's
    # `Prism::ItLocalVariableReadNode` lookup sees the same type as the explicit `|x|` form would.
    #
    # A single yielded `Array[T]` (`ints.each_slice(2) { |g, h| }`) auto-splats like a Tuple does, but with
    # no arity to read: each required / trailing positional binds `T`, a named `*rest` binds `Array[T]`, and
    # an optional positional keeps `Dynamic[Top]` (a short array hands it its default, not `nil`). A short
    # array pads the positionals with `nil` at runtime, so those names — and every name a nested
    # `|(g, h)|` destructure binds from an `Array[T]` slot — are reported as optimistic, and {#bind_onto}
    # records them through `Scope#with_optimistic_local` exactly as the statement-level `a, b = ints` does
    # (issue #1093; the shared rule lives in {MultiTargetBinder}).
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
        @expected_param_types = expected_param_types
        @splat_rest_type = nil
        @optimistic_positions = []
        @optimistic = []
      end

      # The names the last {#bind} bound optimistically nil-free (see the class comment).
      attr_reader :optimistic

      # Binds the block's parameters into `scope`: {#bind}'s types through `Scope#with_local`, then the
      # optimistic mark for every name in {#optimistic}.
      def bind_onto(block_node, scope)
        types = bind(block_node)
        MultiTargetBinder::Result.new(types: types, optimistic: @optimistic.dup.freeze).apply_to(scope)
      end

      # @return ordered map from parameter name to bound type. Anonymous
      #   parameters are skipped; MultiTargetNode destructuring slots delegate to {MultiTargetBinder} and
      #   contribute every named local in declaration order. Numbered-parameter forms (`_1`, `_2`, ...) bind
      #   `:_1`, `:_2`, ... up to the maximum the block body refers to.
      def bind(block_node)
        @optimistic = []
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

      # `|_1, _2|` numbered-parameter form. Prism exposes the implicit count through
      # `NumberedParametersNode#maximum` (the highest `_N` referenced in the body); we materialise bindings
      # for `:_1` through `:_maximum` so the block body's `LocalVariableReadNode` lookups see the same types
      # as the equivalent explicit `|x, y|` form would.
      def bind_numbered_parameters(numbered_node)
        bindings = {}
        numbered_node.maximum.times do |i|
          bindings[:"_#{i + 1}"] = positional_type_at(i)
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

        apply_auto_splat(params_node)

        bindings = {}
        bind_positionals(params_node, bindings, 0)
        bind_rest(params_node, bindings)
        bind_keywords(params_node, bindings)
        bind_keyword_rest(params_node, bindings)
        bind_block_param(params_node, bindings)
        bindings
      end

      # Ruby blocks (NOT lambdas) auto-splat a single yielded Tuple-shaped value when the block declares more
      # than one required positional parameter:
      #
      #   { a: 1 }.each { |k, v| ... }
      #
      # yields `[key, value]` as a single arg, but the two-param block sees `k = key, v = value`. RBS /
      # IteratorDispatch encode this as the block taking ONE `[K, V]` Tuple parameter; without this fix-up
      # the binder would assign `k = Tuple[K, V]` and `v = Dynamic[Top]`, and any call on
      # `k.<method-not-on-Tuple>` would false-fire.
      #
      # The rule fires only when (a) the receiver yields exactly one value (`expected_param_types.size ==
      # 1`), (b) the block declares more than one positional slot, or one plus a rest (`|k, *r|`, and the
      # trailing-comma `|k,|` Prism spells as an `ImplicitRestNode`) — Ruby splats both, while a lone `|*r|`
      # does not — and (c) that single expected element is a Tuple or an `Array[T]` carrier
      # ({MultiTargetBinder.array_element_type}). Multi-arg yields (e.g. `each_with_index`'s `(element,
      # index)` pair) are NOT auto-splatted — matching Ruby semantics where a multi-arg yield to a `|a, b, c|`
      # block fills the extra slot with nil rather than splatting any element.
      def apply_auto_splat(params_node)
        return unless @expected_param_types.size == 1

        pos_count = params_node.requireds.size + params_node.optionals.size + params_node.posts.size
        return unless pos_count > 1 || (pos_count == 1 && !params_node.rest.nil?)

        first = @expected_param_types[0]
        if first.is_a?(Type::Tuple)
          @expected_param_types = first.elements
        elsif (element = MultiTargetBinder.array_element_type(first))
          apply_array_auto_splat(params_node, element)
        end
      end

      # Issue #1093 — the `Array[T]` arm of {#apply_auto_splat}: see the class comment for the per-slot rule.
      def apply_array_auto_splat(params_node, element)
        required = params_node.requireds.size
        optional = params_node.optionals.size
        posts = params_node.posts.size
        @expected_param_types = Array.new(required) { element } +
                                Array.new(optional) { Type::Combinator.untyped } +
                                Array.new(posts) { element }
        @optimistic_positions = (0...required).to_a + ((required + optional)...(required + optional + posts)).to_a
        @splat_rest_type = Type::Combinator.nominal_of("Array", type_args: [element])
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
                                                 optimistic: @optimistic_positions.include?(cursor))
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
