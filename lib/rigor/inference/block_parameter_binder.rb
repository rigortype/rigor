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
    # A single yielded `Array[T]` (`ints.each_slice(2) { |g, h| }`) auto-splats like a Tuple does, but with
    # no arity to read: each required / trailing positional binds `T`, a named `*rest` binds `Array[T]`, and
    # an optional positional keeps `Dynamic[Top]` (a short array hands it its default, not `nil`). A short
    # array pads the positionals with `nil` at runtime, so those names — and every name a nested
    # `|(g, h)|` destructure binds from an `Array[T]` slot — are reported as optimistic, and {#bind_onto}
    # records them through `Scope#with_optimistic_local` exactly as the statement-level `a, b = ints` does
    # (issue #1093; the shared rule lives in {MultiTargetBinder}).
    #
    # A union whose every member is one of those two carriers (`[K, V] | [K]`, `Array[A] | [B, C]`)
    # auto-splats member by member, and each position binds the join of the members' types — `Dynamic[Top]`
    # when any member leaves it unfilled, and without a member's bare `nil` when another fills it (then
    # optimistic) — optimistic too when any member's `Array[T]` arm marked it, as the statement form joins
    # a union right-hand side (issue #1094). A union with any other member does not splat, and a lone value
    # with no `to_ary` is NOT wrapped as `[value]` here the way `a, b = value` wraps it: the one-value premise
    # of auto-splat is the RBS block signature's arity, which the binder cannot check against the yield, and
    # a wrong wrap binds `nil` to a parameter the block receives a value in. A nested `|(g, h)|` destructures
    # the one value the signature already placed, so it wraps like the statement form.
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
        apply_auto_splat(ParameterShape.new(required: arity, optional: 0, post: 0, rest: false))

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

        apply_auto_splat(ParameterShape.of(params_node))

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
      # 1`), (b) the parameter list is one CRuby splats (see {#splatting_parameter_list?}), and (c) that single
      # expected element is a Tuple or an `Array[T]` carrier
      # ({MultiTargetBinder.array_element_type}). Multi-arg yields (e.g. `each_with_index`'s `(element,
      # index)` pair) are NOT auto-splatted — matching Ruby semantics where a multi-arg yield to a `|a, b, c|`
      # block fills the extra slot with nil rather than splatting any element.
      def apply_auto_splat(shape)
        return unless @expected_param_types.size == 1

        return unless splatting_parameter_list?(shape)

        members = auto_splat_members(@expected_param_types[0])
        return if members.nil?

        splats = members.map { |member| auto_splat_of(shape, member) }
        @expected_param_types, softened = join_positional_types(splats.map(&:types))
        @optimistic_positions = (splats.flat_map(&:optimistic_positions) + softened).uniq
        rests = splats.map(&:rest_type)
        @splat_rest_type = rests.include?(nil) ? nil : Type::Combinator.union(*rests)
      end

      # The positional part of a parameter list, as counts: all the auto-splat rule reads. An explicit
      # `BlockParametersNode` list and a numbered-parameter block (`maximum` required positionals) both
      # reduce to it, so the two spellings cannot drift.
      ParameterShape = Data.define(:required, :optional, :post, :rest) do
        def self.of(params_node)
          new(required: params_node.requireds.size, optional: params_node.optionals.size,
              post: params_node.posts.size, rest: !params_node.rest.nil?)
        end
      end
      private_constant :ParameterShape

      # The per-member result of one auto-splat arm: the positional table, the positions it binds
      # optimistically, and the named rest's type (nil for the `Array[Dynamic[Top]]` default).
      AutoSplat = Data.define(:types, :optimistic_positions, :rest_type)
      private_constant :AutoSplat

      # The carriers the value auto-splats as — itself, or every member of a union — or nil when any of them
      # is neither a Tuple nor an `Array[T]`.
      def auto_splat_members(type)
        members = type.is_a?(Type::Union) ? type.members : [type]
        splattable = members.all? { |m| m.is_a?(Type::Tuple) || MultiTargetBinder.array_element_type(m) }
        splattable ? members : nil
      end

      def auto_splat_of(shape, member)
        if member.is_a?(Type::Tuple)
          tuple_auto_splat(shape, member.elements)
        else
          array_auto_splat(shape, MultiTargetBinder.array_element_type(member))
        end
      end

      # Returns the joined table and the positions it softened. A single member's table is used as is; across
      # members, a position any member leaves unfilled (a slot past a short Tuple) or fills with `Dynamic[Top]`
      # stays `Dynamic[Top]`, and a member's bare `nil` drops out of a position another member fills with a
      # value, the position then being optimistic — `MultiTargetBinder`'s cross-member softening.
      def join_positional_types(tables)
        return [tables.first, []] if tables.size == 1

        softened = []
        joined = Array.new(tables.map(&:size).max) do |i|
          column = tables.map { |table| table[i] }
          next Type::Combinator.untyped if column.any? { |t| t.nil? || t == Type::Combinator.untyped }

          firm = column.reject { |t| t.is_a?(Type::Constant) && t.value.nil? }
          next Type::Combinator.union(*column) if firm.empty? || firm.size == column.size

          softened << i
          Type::Combinator.union(*firm)
        end
        [joined, softened]
      end

      # CRuby's own condition (`vm_callee_setup_block_arg` / `setup_parameters_complex`): a block splats a lone
      # array argument when it has a mandatory positional (`lead + post > 0`) or more than one optional, except a
      # bare `|a|` (the iseq's `ambiguous_param0`). So `|k, *r|`, `|*r, v|`, `|a = 1, b = 2|` and the
      # trailing-comma `|k,|` (Prism's `ImplicitRestNode`) splat, while `|*r|`, `|a = 1, *r|` and `|a, &b|` /
      # `|a, k: 1|` do not.
      def splatting_parameter_list?(shape)
        mandatory = shape.required + shape.post
        return false unless mandatory.positive? || shape.optional > 1

        !(mandatory == 1 && shape.optional.zero? && !shape.rest)
      end

      # The Tuple arm of {#apply_auto_splat}. Leading positionals (required, then optional) read from the head;
      # trailing positionals after a rest read from the tail, with the rest absorbing the middle — the split
      # `MultiTargetBinder` applies to `a, *r, b = tuple`, so `|*r, v|` over `[K, V]` binds `v` to `V` and
      # `|a, *r, b|` over `[A, B, C]` binds `b` to `C`. Without a rest the trailing positionals continue from the
      # head (Ruby fills `|a, b = 1, c|` from the head when the tuple is long enough). The split is mirrored
      # rather than delegated to `MultiTargetBinder.decompose_tuple` because that one pads a missing slot with
      # `Constant[nil]` and softens `X | nil`; a block slot past the tuple has always bound `Dynamic[Top]`.
      def tuple_auto_splat(shape, elements)
        head = shape.required + shape.optional
        posts = shape.post
        tail_start = shape.rest ? [elements.size - posts, head].max : head
        types = Array.new(head) { |i| elements[i] } + Array.new(posts) { |j| elements[tail_start + j] }
        AutoSplat.new(types: types, optimistic_positions: [], rest_type: nil)
      end

      # Issue #1093 — the `Array[T]` arm of {#apply_auto_splat}: see the class comment for the per-slot rule.
      def array_auto_splat(shape, element)
        required = shape.required
        optional = shape.optional
        posts = shape.post
        AutoSplat.new(
          types: Array.new(required) { element } + Array.new(optional) { Type::Combinator.untyped } +
                 Array.new(posts) { element },
          optimistic_positions: (0...required).to_a + ((required + optional)...(required + optional + posts)).to_a,
          rest_type: Type::Combinator.nominal_of("Array", type_args: [element])
        )
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
