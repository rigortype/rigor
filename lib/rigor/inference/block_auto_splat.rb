# frozen_string_literal: true

require_relative "../type"
require_relative "multi_target_binder"

module Rigor
  module Inference
    # The auto-splat half of {BlockParameterBinder}: given a block's positional parameter shape and the one
    # value the receiver yields, it answers the positional table the block's names are bound from.
    #
    # Ruby blocks (NOT lambdas) spread a single yielded array-ish value across their positionals, and CRuby
    # decides that on the PARAMETER LIST alone ({ParameterShape#splats?}) — never on the value. So the
    # carrier only decides how precisely each position can be filled, and a carrier this module cannot
    # decompose lowers the positions to `Dynamic[Top]` rather than cancelling the spread (issue #1116).
    #
    # Each member of the carrier (a union distributes; anything else is its own single member) contributes
    # one {Table}, and {join} folds them into the answer:
    #
    # - a `Type::Tuple` spreads element-wise, leading positionals (required, then optional) from the head
    #   and, with a rest present, trailing positionals from the tail with the rest absorbing the middle —
    #   the split `MultiTargetBinder` applies to `a, *r, b = tuple`, so `|*r, v|` over `[K, V]` binds `v` to
    #   `V`. A slot past the tuple is left unfilled and lands on `Dynamic[Top]`;
    # - an `Array[T]` ({MultiTargetBinder.array_element_type}) binds `T` to every required and trailing
    #   positional, `Dynamic[Top]` to every optional one (a short array hands it its default, not `nil`),
    #   and `Array[T]` to a named rest. A short array pads the fixed positions with `nil` at runtime, so
    #   those positions are reported optimistic (issue #1093);
    # - an opaque array carrier — a raw `Array`, an `Array[untyped]` / `Array[top]`, a `Refined` /
    #   `Difference` over either, or a `Dynamic` over any `Array` however precise — binds `Dynamic[Top]` to
    #   every position: the floor `MultiTargetBinder` binds for the same undecomposable right-hand side, and
    #   the reason `[1, 2].tap { |a, b| a.succ }` no longer reads `a` as the whole `Array` (issue #1116);
    # - a bare `nil` binds `nil` to every position. `nil` has no `to_ary`, so CRuby passes it as the one
    #   argument and `|a, b|` sees `nil, nil` — which is also what the wrap `[nil]` pads to, so the two
    #   readings agree here, and {join} takes that `nil` back out of any position another member fills;
    # - every other member takes the same `Dynamic[Top]` floor as the opaque one, and does NOT license the
    #   spread on its own. It is the member the union knows least about, and joining it as a value would put
    #   a nil-bearing element beside a nil-free one: `String#scan`'s `String | Array[String?]` yield joins a
    #   capture's `String?` against the whole match's `String` and fires `call.possible-nil-receiver` on the
    #   correlated-invariant `refinements[name.to_sym]`, which ADR-5 ranks above the precision.
    #
    # The spread needs at least one Tuple, `Array[T]` or opaque array member; a carrier with none of them
    # ({#for} answers nil) leaves the binder's declared types alone, which binds the value to the first
    # parameter and `Dynamic[Top]` after. So a lone value with no `to_ary` is NOT wrapped as `[value]` the
    # way `a, b = value` wraps it: the one-value premise of auto-splat is the RBS block signature's arity,
    # which nothing here can check against the actual yield, and a wrong wrap binds `nil` to a parameter the
    # block receives a value in.
    #
    # See docs/internal-spec/inference-engine.md for the binding contract.
    module BlockAutoSplat
      # The positional part of a parameter list, as counts: all the auto-splat rule reads. An explicit
      # `BlockParametersNode` list and a numbered-parameter block (`maximum` required positionals) both
      # reduce to it, so the two spellings cannot drift.
      ParameterShape = Data.define(:required, :optional, :post, :rest) do
        def self.of(params_node)
          new(required: params_node.requireds.size, optional: params_node.optionals.size,
              post: params_node.posts.size, rest: !params_node.rest.nil?)
        end

        # The `_1` / `_2` form, read as the explicit list of `arity` required positionals.
        def self.of_arity(arity)
          new(required: arity, optional: 0, post: 0, rest: false)
        end

        def positional_count = required + optional + post

        # CRuby's own condition (`vm_callee_setup_block_arg` / `setup_parameters_complex`): a block splats a
        # lone array argument when it has a mandatory positional (`lead + post > 0`) or more than one
        # optional, except a bare `|a|` (the iseq's `ambiguous_param0`). So `|k, *r|`, `|*r, v|`,
        # `|a = 1, b = 2|` and the trailing-comma `|k,|` (Prism's `ImplicitRestNode`) splat, while `|*r|`,
        # `|a = 1, *r|` and `|a, &b|` / `|a, k: 1|` do not.
        def splats?
          mandatory = required + post
          return false unless mandatory.positive? || optional > 1

          !(mandatory == 1 && optional.zero? && !rest)
        end
      end

      # A positional table: the type per position, the positions bound optimistically, and the named rest's
      # type (nil for the `Array[Dynamic[Top]]` default). One arm produces one; {join} folds them into one.
      # Private as a name — {#for} hands the folded value out, and nothing outside constructs one.
      Table = Data.define(:types, :optimistic_positions, :rest_type)
      private_constant :Table

      # The arm kinds that make a member an array as far as the spread is concerned, so that a union
      # carrying one of them spreads even where its other members do not decompose.
      ARRAY_CARRIER_ARMS = %i[tuple array opaque].freeze
      private_constant :ARRAY_CARRIER_ARMS

      module_function

      # @param shape — the block's {ParameterShape}.
      # @param carrier — the one value the receiver yields.
      # @return the folded {Table}, or nil when no member is an array carrier and the
      #   spread must leave the declared types alone.
      def for(shape, carrier)
        arms = arms_of(carrier)
        return nil if arms.nil?

        join(arms.map { |member, kind| table_for(shape, member, kind) })
      end

      def arms_of(carrier)
        members = carrier.is_a?(Type::Union) ? carrier.members : [carrier]
        arms = members.map { |member| [member, arm_of(member)] }
        arms.any? { |_, kind| ARRAY_CARRIER_ARMS.include?(kind) } ? arms : nil
      end

      def arm_of(member)
        return :tuple if member.is_a?(Type::Tuple)
        return :array if MultiTargetBinder.array_element_type(member)
        return :opaque if opaque_array_carrier?(member)
        return :nil_value if nil_literal?(member)

        :unknown
      end

      # A carrier that is an array the module may not decompose into per-position types: the raw `Array`, an
      # `Array[untyped]` / `Array[top]`, a `Refined` / `Difference` over either, and a `Dynamic` over ANY
      # carrier that would license the spread — `Dynamic[Array[Integer]]`, `Dynamic[[Integer, String]]`,
      # `Dynamic[Array[Integer] | nil]` alike. {MultiTargetBinder.array_element_type} declines every
      # `Dynamic` wrapper on purpose: the value is gradual, and projecting its static facet would hand each
      # position a bare `T` that licenses the negative rules (issue #1093, ADR-5). That is a reason to floor
      # the positions, not a reason to leave the whole value on the first parameter, so the facet decides
      # only whether CRuby would splat.
      def opaque_array_carrier?(type)
        case type
        when Type::Nominal then type.class_name == "Array"
        when Type::Refined, Type::Difference then opaque_array_carrier?(type.base)
        when Type::Dynamic then !arms_of(type.static_facet).nil?
        else false
        end
      end

      def table_for(shape, member, kind)
        case kind
        when :tuple then tuple_table(shape, member.elements)
        when :array then array_table(shape, MultiTargetBinder.array_element_type(member))
        when :nil_value then uniform_table(shape, member)
        else uniform_table(shape, Type::Combinator.untyped)
        end
      end

      # The split is mirrored rather than delegated to `MultiTargetBinder.decompose_tuple` because that one
      # pads a missing slot with `Constant[nil]` and softens `X | nil`; a block slot past the tuple has
      # always bound `Dynamic[Top]`. Without a rest the trailing positionals continue from the head (Ruby
      # fills `|a, b = 1, c|` from the head when the tuple is long enough).
      def tuple_table(shape, elements)
        head = shape.required + shape.optional
        posts = shape.post
        tail_start = shape.rest ? [elements.size - posts, head].max : head
        types = Array.new(head) { |i| elements[i] } + Array.new(posts) { |j| elements[tail_start + j] }
        Table.new(types: types, optimistic_positions: [], rest_type: nil)
      end

      def array_table(shape, element)
        required = shape.required
        optional = shape.optional
        posts = shape.post
        Table.new(
          types: Array.new(required) { element } + Array.new(optional) { Type::Combinator.untyped } +
                 Array.new(posts) { element },
          optimistic_positions: (0...required).to_a + ((required + optional)...(required + optional + posts)).to_a,
          rest_type: Type::Combinator.nominal_of("Array", type_args: [element])
        )
      end

      # One type for every position: the `Dynamic[Top]` floor of a member the module cannot decompose, or
      # the `nil` a `nil` member hands each of them. The `nil` rest_type leaves a named rest on the binder's
      # `Array[Dynamic[Top]]` default, which is right for both — CRuby gives `nil.tap { |a, *r| }` an empty
      # `r`, and an opaque carrier says nothing about the leftovers.
      def uniform_table(shape, type)
        Table.new(types: Array.new(shape.positional_count) { type }, optimistic_positions: [], rest_type: nil)
      end

      # A single member's table is used as is. Across members, a position any member leaves unfilled (a slot
      # past a short Tuple) or fills with `Dynamic[Top]` stays `Dynamic[Top]`, and a member's bare `nil`
      # drops out of a position another member fills with a value, that position then being optimistic —
      # `MultiTargetBinder`'s cross-member softening. A named rest joins only when every member supplies
      # one; otherwise the binder's `Array[Dynamic[Top]]` default stands.
      def join(tables)
        types, softened = join_types(tables.map(&:types))
        rests = tables.map(&:rest_type)
        Table.new(
          types: types,
          optimistic_positions: (tables.flat_map(&:optimistic_positions) + softened).uniq,
          rest_type: rests.include?(nil) ? nil : Type::Combinator.union(*rests)
        )
      end

      # @return the joined table and the positions it softened.
      def join_types(tables)
        return [tables.first, []] if tables.size == 1

        softened = []
        joined = Array.new(tables.map(&:size).max) do |i|
          column = tables.map { |table| table[i] }
          next Type::Combinator.untyped if column.any? { |t| t.nil? || t == Type::Combinator.untyped }

          firm = column.reject { |t| nil_literal?(t) }
          next Type::Combinator.union(*column) if firm.empty? || firm.size == column.size

          softened << i
          Type::Combinator.union(*firm)
        end
        [joined, softened]
      end

      def nil_literal?(type) = type.is_a?(Type::Constant) && type.value.nil?

      # {#for} is the whole surface; the arms and the fold are this module's own business, and keeping them
      # off the singleton stops a caller reaching past the fold for one member's table.
      private_class_method :arms_of, :arm_of, :opaque_array_carrier?, :table_for, :tuple_table, :array_table,
                           :uniform_table, :join, :join_types, :nil_literal?
    end
  end
end
