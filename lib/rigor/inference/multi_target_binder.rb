# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "optimistic_origin"
require_relative "method_dispatcher/rbs_dispatch"

module Rigor
  module Inference
    # Slice 5 phase 2 sub-phase 2 destructuring binder.
    #
    # `Rigor::Inference::MultiTargetBinder` decomposes a tuple- or array-shaped right-hand side type
    # against a Prism multi-target tree and produces a `name -> Rigor::Type` binding map. The
    # binder is shared between three surfaces:
    #
    # 1. `Rigor::Inference::StatementEvaluator#eval_multi_write` for the statement-level `a, b =
    #    rhs` form (`Prism::MultiWriteNode`).
    # 2. `Rigor::Inference::BlockParameterBinder` for nested destructuring inside block parameter
    #    lists (`Prism::MultiTargetNode` under `BlockParametersNode#requireds`).
    # 3. `Rigor::Inference::StatementEvaluator#bind_for_index` for `for a, b in pairs`.
    #
    # Both Prism nodes share the same `lefts` / `rest` (a `Prism::SplatNode`) / `rights` triple,
    # so the binder treats them uniformly. The binder is pure: it MUST NOT mutate its inputs and
    # MUST return a fresh `Hash` on every call.
    #
    # Per-carrier rule for the right-hand side:
    #
    # - `Type::Tuple` (known arity) decomposes element-wise; see {slot_type} for the softening.
    # - `Nominal[Array, [T]]`, and a `Refined` / `Difference` over one (`non-empty-array[T]`
    #   after an `empty?` guard), binds every fixed front/back slot to `T` and a named rest to
    #   `Array[T]` (issue #1093). A short array pads the fixed slots with `nil` at runtime, so
    #   `T` is the same optimistic read `Array#[]` / `Array#first` get past core RBS's
    #   `%a{implicitly-returns-nil}`: the binder reports those names in {Result#optimistic}, and
    #   every caller that applies the bindings to a scope records them through
    #   `Scope#with_optimistic_local` ({Result#apply_to}) so the ADR-101 branch elision
    #   declines on them. A nested target under an optimistic slot inherits the mark (`nil`
    #   destructures to `nil` for every inner name); the rest never carries it.
    # - A `Type::Union` distributes (issue #1094): each member decomposes on its own against the
    #   same target tree, and each name binds the join of its per-member types. A member that binds
    #   a name to `Dynamic[Top]` — every name, for a member no rule here decomposes — makes that
    #   name `Dynamic[Top]` for the whole union rather than dropping out of the join. A member that
    #   binds a name to bare `nil` while another binds a value drops out of that name's join, and
    #   the name is marked optimistic: the per-slot softening of {slot_type}, applied across
    #   members (see {join_member_bindings}). So `a, b = ints[1..]` (`Array[Integer] | nil`) binds
    #   `Integer` to each slot, marked, exactly as a short `ints` would. A name is also optimistic
    #   when any member marked it, the rule `Scope#join` applies to the same mark at a merge.
    # - A value that provably has no implicit `to_ary` conversion
    #   ({MethodDispatcher::RbsDispatch.array_conversion_free?}: `Integer`, `String`, `Hash`,
    #   `nil`, ... and RBS-known classes whose ancestry neither defines `to_ary` nor overrides
    #   `method_missing` / `respond_to_missing?`) is what Ruby wraps as `[rhs]`, so it decomposes
    #   as that one-element `Tuple` (issue #1094): `a, b = 1` binds `1` and `nil`. The wrap is
    #   exact rather than a bet, so it adds no mark.
    # - Everything else — raw `Array`, `Array[Dynamic[top]]`, `Dynamic[Array[T]]` (whose static
    #   facet must not surface as a bare `T`), a value that may convert (`SimpleDelegator`, a
    #   Ruby-source class, a module, `Object`), `Top`, `Bot` — collapses to `Dynamic[Top]` per
    #   slot.
    #
    # Targets the binder recognises:
    #
    # - `Prism::LocalVariableTargetNode` — used by the statement-level `a, b = rhs` form. Binds
    #   `target.name` to its slice of the right-hand side.
    # - `Prism::RequiredParameterNode` — used by block-parameter destructuring (`|(a, b), c|`).
    #   Prism encodes the inner names of a block-side `MultiTargetNode` as parameter nodes
    #   rather than target nodes; the binder treats them uniformly with their
    #   `LocalVariableTargetNode` cousins because they carry the same `name:` field and the
    #   same observable semantics (binding a fresh local in the block-entry scope).
    # - `Prism::MultiTargetNode` — recurses with the slot's type as the new right-hand side.
    # - `Prism::SplatNode` (used for `rest`) — its `expression` MUST be a
    #   `Prism::LocalVariableTargetNode` or a `Prism::RequiredParameterNode` to be observable;
    #   an anonymous `*` splat or a non-local target is skipped.
    #
    # Other target kinds (`InstanceVariableTargetNode`, `ConstantTargetNode`,
    # `IndexTargetNode`, `CallTargetNode`, `ConstantPathTargetNode`, `ImplicitRestNode`, ...)
    # MUST be silently skipped: they have no observable contribution to the local-variable scope
    # the StatementEvaluator threads.
    #
    # See docs/internal-spec/inference-engine.md for the binding contract and
    # docs/adr/4-type-inference-engine.md for the slice rationale.
    module MultiTargetBinder
      # `types` is the `name -> Rigor::Type` map {.bind} returns; `optimistic` the frozen list of
      # names whose nil-freeness is the short-array bet described in the module comment.
      Result = Data.define(:types, :optimistic) do
        # Binds every name into `scope` and records the optimistic mark after the binding, since
        # `Scope#with_local` drops any mark the name carried before.
        def apply_to(scope)
          bound = types.reduce(scope) { |acc, (name, type)| acc.with_local(name, type) }
          optimistic.reduce(bound) do |acc, name|
            acc.with_optimistic_local(name, OptimisticOrigin::IMPLICITLY_RETURNS_NIL)
          end
        end
      end

      module_function

      # @param rhs_type — type of the right-hand side
      # @param scope — the scope the destructure is evaluated in, which answers the `to_ary`
      #   question for a class outside the core list; without one only the core list wraps.
      def bind(target_node, rhs_type, scope: nil)
        bind_marked(target_node, rhs_type, scope: scope).types
      end

      # @param optimistic — whether `rhs_type` itself is an optimistic slot of an enclosing
      #   decomposition (a block's `|(g, h)|` fed from an auto-splatted `Array[T]`), in which case
      #   every name bound under it inherits the mark.
      def bind_marked(target_node, rhs_type, optimistic: false, scope: nil)
        bindings = {}
        marked = []
        visit(target_node, rhs_type, optimistic, bindings, marked, scope)
        Result.new(types: bindings, optimistic: marked.freeze)
      end

      # The `T` of an `Array[T]` carrier the binder may decompose, or nil. Declines raw `Array`
      # and an untyped / top element, which bind `Dynamic[Top]` per slot as before, and every
      # `Dynamic` wrapper: `Dynamic[Array[T]]` is gradual, and projecting its static facet would
      # hand the slot a bare `T` that licenses the negative rules (ADR-5). Shared with
      # {BlockParameterBinder}'s auto-splat so both surfaces accept the same carriers.
      def array_element_type(type)
        case type
        when Type::Nominal
          return nil unless type.class_name == "Array" && type.type_args.size == 1

          element = type.type_args.first
          element.is_a?(Type::Dynamic) || element.is_a?(Type::Top) ? nil : element
        when Type::Refined, Type::Difference
          array_element_type(type.base)
        end
      end

      # The class whose instances `type` describes, for the `to_ary` question, or nil when `type`
      # names no single class: `Dynamic`, `Top`, `Singleton`, `Intersection` and the rest decline.
      # A union never reaches here; the binder distributes it first.
      def conversion_class_name(type)
        case type
        when Type::Constant then type.value.class.name
        when Type::Nominal then type.class_name
        when Type::HashShape then "Hash"
        when Type::IntegerRange then "Integer"
        when Type::Refined, Type::Difference then conversion_class_name(type.base)
        end
      end

      class << self
        private

        def visit(node, rhs_type, optimistic, bindings, marked, scope)
          return visit_union(node, rhs_type.members, optimistic, bindings, marked, scope) if rhs_type.is_a?(Type::Union)

          lefts = node.lefts || []
          rest = node.rest
          rights = node.rights || []

          fronts, rest_type, backs, slots_optimistic =
            decompose(rhs_type, lefts.size, rights.size, rest_present: !rest.nil?, scope: scope)
          rest_type = arity_free_rest(rest_type) if optimistic
          slot_mark = optimistic || slots_optimistic
          lefts.each_with_index { |t, i| bind_target(t, fronts[i], slot_mark, bindings, marked, scope) }
          bind_rest_target(rest, rest_type, bindings, marked) if rest
          rights.each_with_index { |t, i| bind_target(t, backs[i], slot_mark, bindings, marked, scope) }
        end

        # Every member walks the same target tree, so each binds the same names; the first member's
        # key order is the declaration order.
        def visit_union(node, members, optimistic, bindings, marked, scope)
          walks = members.map do |member|
            member_bindings = {}
            member_marked = []
            visit(node, member, optimistic, member_bindings, member_marked, scope)
            [member_bindings, member_marked]
          end
          walks.first.first.each_key do |name|
            types = walks.map { |member_bindings, _| member_bindings[name] }
            joined, softened = join_member_bindings(types)
            mark = softened || walks.any? { |_, member_marked| member_marked.include?(name) }
            bind_name(name, joined, mark, bindings, marked)
          end
        end

        # Returns `[type, softened]`. `Dynamic[Top]` from any member is the whole answer: the join
        # must not let a decomposable member's precise type stand for a member nothing is known
        # about. A member that binds the name to bare `nil` — a `nil` slot, a slot past a short
        # member, or a `nil` member wrapped as `[nil]` — is left out of the join when another member
        # binds a value, and `softened` reports it so the caller marks the name optimistic. This is
        # {slot_type}'s ADR-57 softening across members: which member arrived is correlated with the
        # other slots (`k, v = hash.find { ... }; v.x if k`, `status, value = ok ? [:ok, v] : [:err]`),
        # and a per-slot `T | nil` fires `call.possible-nil-receiver` on the guarded read.
        def join_member_bindings(types)
          untyped = Type::Combinator.untyped
          return [untyped, false] if types.any? { |type| type == untyped }

          firm = types.reject { |type| nil_literal?(type) }
          return [Type::Combinator.union(*types), false] if firm.empty? || firm.size == types.size

          [Type::Combinator.union(*firm), true]
        end

        # Decomposes the right-hand side type into the per-slot types. Returns a `[fronts,
        # rest_type, backs, optimistic]` quadruple, with `fronts` and `backs` each an ordered
        # array of length `front_count`/`back_count`, `rest_type` either a `Rigor::Type` (when
        # `rest_present:` is true) or `nil`, and `optimistic` true when the fixed slots are the
        # short-array bet rather than known elements.
        def decompose(rhs_type, front_count, back_count, rest_present:, scope:)
          if rhs_type.is_a?(Type::Tuple)
            [*decompose_tuple(rhs_type, front_count, back_count, rest_present: rest_present), false]
          elsif (element = array_element_type(rhs_type))
            [*decompose_array(element, front_count, back_count, rest_present: rest_present), true]
          elsif wraps_as_single_element?(rhs_type, scope)
            wrapped = Type::Combinator.tuple_of(rhs_type)
            [*decompose_tuple(wrapped, front_count, back_count, rest_present: rest_present), false]
          else
            [*decompose_default(front_count, back_count, rest_present: rest_present), false]
          end
        end

        # Ruby's `[rhs]` wrap for a value with no implicit `to_ary`; see the module comment.
        def wraps_as_single_element?(rhs_type, scope)
          class_name = conversion_class_name(rhs_type)
          !class_name.nil? && MethodDispatcher::RbsDispatch.array_conversion_free?(class_name, scope)
        end

        # Under an inherited mark the whole right-hand side may be the `nil` a short outer array padded in, and
        # `(p, *q) = nil` binds `q = []`. A Tuple rest would claim the middle elements are present
        # (`q.first.nil?` folding to `false`), so it widens to `Array[union of the middle]`, which admits the
        # empty array; an empty middle has no element type to offer and stays `Array[Dynamic[top]]`.
        def arity_free_rest(rest_type)
          return rest_type unless rest_type.is_a?(Type::Tuple)

          element = rest_type.elements.empty? ? Type::Combinator.untyped : Type::Combinator.union(*rest_type.elements)
          Type::Combinator.nominal_of("Array", type_args: [element])
        end

        def decompose_array(element, front_count, back_count, rest_present:)
          [
            Array.new(front_count) { element },
            rest_present ? Type::Combinator.nominal_of("Array", type_args: [element]) : nil,
            Array.new(back_count) { element }
          ]
        end

        def decompose_tuple(tuple, front_count, back_count, rest_present:)
          elements = tuple.elements
          fronts = Array.new(front_count) { |i| slot_type(elements, i) }
          if rest_present
            middle_end = [elements.size - back_count, front_count].max
            middle = elements[front_count...middle_end] || []
            rest_type = Type::Combinator.tuple_of(*middle)
            backs = Array.new(back_count) { |i| slot_type(elements, middle_end + i) }
          else
            rest_type = nil
            backs = Array.new(back_count) { |i| slot_type(elements, front_count + i) }
          end
          [fronts, rest_type, backs]
        end

        # The per-slot type for index `i` of a tuple decomposition, FP-safely softened: a
        # missing slot is `nil` (the runtime value of an over-destructured positional), and a
        # PRESENT but nil-bearing slot (`X | nil`) is softened to its non-`nil` part — for a
        # heterogeneous `Tuple` whose optional slot was made optional by flow.
        #
        # Rationale (ADR-57 slice 3 work-item 2): a destructure of a tuple element that flow
        # typed as optional is almost always guarded by a CORRELATED invariant the flow engine
        # cannot prove. The canonical case is haml's `parse_tag`, which returns `[...,
        # last_line || @line.index + 1]` — a 9-tuple whose `last_line` slot widens to
        # `Dynamic[top]?` through a loop-nested destructure; at the call site `..., last_line =
        # parse_tag(text); raise(..., last_line - 1) if parse && value.empty?` the `last_line`
        # is nil ONLY when an earlier element is too, and the guard short-circuits — but that
        # correlation lives across slots, so per-slot flow sees `last_line` as nil-able and
        # `last_line - 1` fires a spurious `possible nil receiver`. Manufacturing a `T?` for
        # every destructured slot frightens working code; FP discipline (the program works)
        # outranks the worst-case per-slot reading, so we drop the `nil` from a destructured slot
        # and keep the non-`nil` constituent (a bare `nil` slot stays `nil` — there is nothing to
        # soften). A pure non-optional element keeps its precise type unchanged.
        def slot_type(elements, index)
          element = elements[index]
          return Type::Combinator.constant_of(nil) if element.nil?

          soften_optional_slot(element)
        end

        def soften_optional_slot(element)
          return element unless element.is_a?(Type::Union)
          return element unless element.members.any? { |m| nil_literal?(m) }

          non_nil = element.members.reject { |m| nil_literal?(m) }
          return element if non_nil.empty? # a bare `nil` slot: nothing to soften

          Type::Combinator.union(*non_nil)
        end

        def nil_literal?(member)
          member.is_a?(Type::Constant) && member.value.nil?
        end

        def decompose_default(front_count, back_count, rest_present:)
          [
            Array.new(front_count) { Type::Combinator.untyped },
            rest_present ? Type::Combinator.untyped : nil,
            Array.new(back_count) { Type::Combinator.untyped }
          ]
        end

        def bind_target(target, type, optimistic, bindings, marked, scope)
          case target
          when Prism::LocalVariableTargetNode, Prism::RequiredParameterNode
            bind_name(target.name, type, optimistic, bindings, marked)
          when Prism::MultiTargetNode
            visit(target, type, optimistic, bindings, marked, scope)
          end
        end

        # The rest is an `Array` even when the right-hand side is short, so it is never marked.
        def bind_rest_target(splat_node, type, bindings, marked)
          return unless splat_node.is_a?(Prism::SplatNode)

          expression = splat_node.expression
          case expression
          when Prism::LocalVariableTargetNode, Prism::RequiredParameterNode
            bind_name(expression.name, type, false, bindings, marked)
          end
        end

        # A later binding of the same name (`a, a = ints`) wins, mark included.
        def bind_name(name, type, optimistic, bindings, marked)
          bindings[name] = type
          marked.delete(name)
          marked << name if optimistic
        end
      end
    end
  end
end
