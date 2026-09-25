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
    # binder is shared between four surfaces:
    #
    # 1. `Rigor::Inference::StatementEvaluator#eval_multi_write` for the statement-level `a, b =
    #    rhs` form (`Prism::MultiWriteNode`).
    # 2. `Rigor::Inference::BlockParameterBinder` for nested destructuring inside block parameter
    #    lists (`Prism::MultiTargetNode` under `BlockParametersNode#requireds`).
    # 3. `Rigor::Inference::StatementEvaluator#bind_for_index` for `for a, b in pairs`.
    # 4. `Rigor::Inference::ScopeIndexer`'s class-ivar pre-pass, for the ivar targets of `@a, @b = rhs`
    #    (issue #1110), which records {Result#ivars} and drops the marks, as it does for `@x = xs.first`,
    #    with `soften_slots: false` (see {.bind_marked}).
    # 5. `Rigor::Inference::StatementEvaluator`'s `case/in` pattern binding (issue #1122), through
    #    {.decompose_slots}: a pattern binds its names against the same carriers, minus the two
    #    statement-only properties that method documents.
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
    #   `Prism::LocalVariableTargetNode`, a `Prism::RequiredParameterNode`, a
    #   `Prism::InstanceVariableTargetNode` or a `Prism::IndexTargetNode` to be observable; an
    #   anonymous `*` splat or any other target is skipped.
    # - `Prism::InstanceVariableTargetNode` (issue #1110), as a fixed slot, a rest
    #   (`*@rest`), or inside a nested target. It decomposes by the same carrier rules as a
    #   local and is reported apart, in {Result#ivars} / {Result#optimistic_ivars}, so a caller
    #   that threads only locals never sees it. The binder keys it internally by its `:@name`,
    #   which no local name can collide with.
    # - `Prism::IndexTargetNode` (`h[:a], x = rhs`), in the same three positions. It binds no
    #   name: it stores its slot through `[]=` on its receiver. The binder reports the value it
    #   stores in {Result#index_targets}, keyed by the target node itself, so
    #   `StatementEvaluator#eval_multi_write` and `#bind_for_index` (`for h[:a], w in pairs`) can
    #   widen the receiver's literal shape with that value as content evidence, exactly as a plain
    #   `h[:a] = 1` does. It carries no optimistic mark: there is no binding for one to qualify.
    #   Its slot is softened as a local's is; `eval_multi_write` documents why that stays honest
    #   without the mark.
    #
    # Other target kinds (`ClassVariableTargetNode`, `GlobalVariableTargetNode`,
    # `ConstantTargetNode`, `CallTargetNode`, `ConstantPathTargetNode`, `ImplicitRestNode`, ...)
    # MUST be silently skipped: they have no observable contribution to the scope the
    # StatementEvaluator threads.
    #
    # See docs/internal-spec/inference-engine.md for the binding contract and
    # docs/adr/4-type-inference-engine.md for the slice rationale.
    module MultiTargetBinder
      NO_BINDINGS = {}.freeze
      NO_NAMES = [].freeze
      private_constant :NO_BINDINGS, :NO_NAMES

      # `types` is the local `name -> Rigor::Type` map {.bind} returns; `optimistic` the frozen list
      # of local names whose nil-freeness is the short-array bet described in the module comment.
      # `ivars` / `optimistic_ivars` are the same pair for instance-variable targets.
      # `index_targets` maps each `Prism::IndexTargetNode` to the value it stores; {#apply_to}
      # binds nothing for it.
      Result = Data.define(:types, :optimistic, :ivars, :optimistic_ivars, :index_targets) do
        def initialize(types:, optimistic:, ivars: NO_BINDINGS, optimistic_ivars: NO_NAMES,
                       index_targets: NO_BINDINGS)
          super
        end

        # Binds every name into `scope` and records the optimistic mark after the binding, since
        # `Scope#with_local` / `Scope#with_ivar` drop any mark the name carried before. `miss` is what
        # each marked slot answers on a miss (issue #1302): `nil` for every mark the binder makes itself —
        # a short array pads with `nil`, and a `nil` destructures to `nil` — so only a caller whose
        # right-hand side a miss can make something else passes another answer
        # ({OptimisticOrigin.destructuring_miss}).
        def apply_to(scope, miss: nil)
          bound = types.reduce(scope) { |acc, (name, type)| acc.with_local(name, type) }
          bound = ivars.reduce(bound) { |acc, (name, type)| acc.with_ivar(name, type) }
          bound = optimistic.reduce(bound) do |acc, name|
            acc.with_optimistic_local(name, OptimisticOrigin::IMPLICITLY_RETURNS_NIL, miss: miss)
          end
          optimistic_ivars.reduce(bound) do |acc, name|
            acc.with_optimistic_ivar(name, OptimisticOrigin::IMPLICITLY_RETURNS_NIL, miss: miss)
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
      #   decomposition (a block's `|(g, h)|` fed from an auto-splatted `Array[T]`) or an
      #   optimistically nil-free value (`k, v = xs.first`), in which case every name bound under it
      #   inherits the mark. It may instead be the per-element Array
      #   {OptimisticOrigin.destructuring_marks} builds for a literal right-hand side
      #   (`x, y = xs.first, 1`), which marks the names under each fixed slot by that slot's element.
      # @param soften_slots — false keeps a present `X | nil` tuple slot and a union member's bare
      #   `nil` in the binding instead of applying the ADR-57 softening of {slot_type} /
      #   {join_member_bindings}. That softening is only honest together with the optimistic mark
      #   it records, so a consumer that drops the marks (the class-ivar seed, issue #1110) turns it
      #   off; the `Array[T]` bet is unaffected, matching what `@x = xs.first` records.
      def bind_marked(target_node, rhs_type, optimistic: false, scope: nil, soften_slots: true)
        bindings = {}
        marked = []
        visit(target_node, rhs_type, optimistic, bindings, marked, [scope, soften_slots])
        split_result(bindings, marked)
      end

      # The per-slot types of a positional pattern (`in [i, s]`, `in [*pre, m, *post]`), sharing
      # every carrier rule {.bind_marked} applies to a multi-write target except two statement-only
      # properties (issue #1122):
      #
      # - the multi-assign `[rhs]` wrap is NOT applied. `a, b = 1` binds `a` to `1` because Ruby wraps
      #   a right-hand side with no implicit `to_ary`; an array pattern instead matches through the
      #   subject's `deconstruct` / `to_ary`, and a subject with neither raises
      #   `NoMatchingPatternError` — no body is reached, so binding `1` there would type dead code.
      # - no optimistic mark is reported. The ADR-101 short-array bet exists because a SHORT
      #   right-hand side pads the fixed slots with `nil`; a pattern that matched has every fixed slot
      #   it named, so there is nothing to bet on and `Result#optimistic` has no counterpart here.
      #
      # A `Type::Union` is the caller's to distribute: a pattern matches SOME member, and only the
      # caller can tell which members can match it at all. Returns `[fronts, rest_type, backs]`, with
      # every carrier no rule decomposes answering `Dynamic[Top]` per slot — the floor.
      def decompose_slots(rhs_type, front_count:, back_count:, rest_present:, scope: nil, soften_slots: true)
        fronts, rest_type, backs, = decompose(
          rhs_type, front_count, back_count, rest_present: rest_present,
                                             context: [scope, soften_slots], wrap_single: false
        )
        [fronts, rest_type, backs]
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

        # Partitions the walk's single map: an ivar name carries its `@` sigil, which a local name
        # never does, and an index target is keyed by its node rather than by a name.
        def split_result(bindings, marked)
          return Result.new(types: bindings, optimistic: marked.freeze) if bindings.each_key.all? { |k| local_key?(k) }

          grouped = bindings.group_by { |key, _| key_kind(key) }.transform_values(&:to_h)
          ivar_marked, local_marked = marked.partition { |name| key_kind(name) == :ivar }
          Result.new(types: grouped.fetch(:local, {}), optimistic: local_marked.freeze,
                     ivars: grouped.fetch(:ivar, NO_BINDINGS), optimistic_ivars: ivar_marked.freeze,
                     index_targets: grouped.fetch(:index, NO_BINDINGS))
        end

        def local_key?(key) = key.is_a?(Symbol) && !key.start_with?("@")

        def key_kind(key)
          return :index unless key.is_a?(Symbol)

          key.start_with?("@") ? :ivar : :local
        end

        # `context` is the `[scope, soften_slots]` pair every step of the walk shares.
        def visit(node, rhs_type, optimistic, bindings, marked, context)
          if rhs_type.is_a?(Type::Union)
            return visit_union(node, rhs_type.members, optimistic, bindings, marked, context)
          end

          lefts = node.lefts || []
          rest = node.rest
          rights = node.rights || []
          rest_present = !rest.nil?

          fronts, rest_type, backs, slots_optimistic =
            decompose(rhs_type, lefts.size, rights.size, rest_present: rest_present, context: context)
          rest_type = arity_free_rest(rest_type) if optimistic == true
          front_marks, back_marks =
            slot_marks(optimistic, slots_optimistic, rhs_type, [lefts.size, rights.size], rest_present: rest_present)
          lefts.each_with_index { |t, i| bind_target(t, fronts[i], front_marks[i], bindings, marked, context) }
          bind_rest_target(rest, rest_type, bindings, marked) if rest
          rights.each_with_index { |t, i| bind_target(t, backs[i], back_marks[i], bindings, marked, context) }
        end

        # The `[front_marks, back_marks]` pair a visit hands its fixed slots. A boolean `optimistic`
        # applies to every slot, as does the decomposition's own short-array bet (`fallback`, the
        # issue #1093 `Array[T]` mark). A per-element Array applies only to the `Type::Tuple` a literal
        # right-hand side types as, of the same arity, and each slot picks its element at the offset
        # {decompose_tuple} reads ({slot_offsets}); any other carrier falls back to `fallback`, and a
        # slot past the literal's end binds an exact `nil` that no mark qualifies.
        def slot_marks(optimistic, fallback, rhs_type, (front_count, back_count), rest_present:)
          literal = optimistic.is_a?(Array) && rhs_type.is_a?(Type::Tuple) && rhs_type.elements.size == optimistic.size
          uniform = optimistic.is_a?(Array) ? fallback : optimistic || fallback
          return [[uniform] * front_count, [uniform] * back_count] unless literal

          slot_offsets(optimistic.size, front_count, back_count, rest_present: rest_present)
            .map { |offsets| offsets.map { |i| optimistic.fetch(i, false) } }
        end

        # Every member walks the same target tree, so each binds the same names; the first member's
        # key order is the declaration order.
        def visit_union(node, members, optimistic, bindings, marked, context)
          walks = members.map do |member|
            member_bindings = {}
            member_marked = []
            visit(node, member, optimistic, member_bindings, member_marked, context)
            [member_bindings, member_marked]
          end
          walks.first.first.each_key do |name|
            types = walks.map { |member_bindings, _| member_bindings[name] }
            joined, softened = join_member_bindings(types, context.last)
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
        def join_member_bindings(types, soften_slots)
          untyped = Type::Combinator.untyped
          return [untyped, false] if types.any? { |type| type == untyped }

          firm = types.reject { |type| nil_literal?(type) }
          return [Type::Combinator.union(*types), false] if !soften_slots || firm.empty? || firm.size == types.size

          [Type::Combinator.union(*firm), true]
        end

        # Decomposes the right-hand side type into the per-slot types. Returns a `[fronts,
        # rest_type, backs, optimistic]` quadruple, with `fronts` and `backs` each an ordered
        # array of length `front_count`/`back_count`, `rest_type` either a `Rigor::Type` (when
        # `rest_present:` is true) or `nil`, and `optimistic` true when the fixed slots are the
        # short-array bet rather than known elements.
        def decompose(rhs_type, front_count, back_count, rest_present:, context:, wrap_single: true)
          scope, soften = context
          if rhs_type.is_a?(Type::Tuple)
            [*decompose_tuple(rhs_type, front_count, back_count, rest_present: rest_present, soften: soften), false]
          elsif (element = array_element_type(rhs_type))
            [*decompose_array(element, front_count, back_count, rest_present: rest_present), true]
          elsif wrap_single && wraps_as_single_element?(rhs_type, scope)
            wrapped = Type::Combinator.tuple_of(rhs_type)
            [*decompose_tuple(wrapped, front_count, back_count, rest_present: rest_present, soften: soften), false]
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

        def decompose_tuple(tuple, front_count, back_count, rest_present:, soften:)
          elements = tuple.elements
          fronts, backs = slot_offsets(elements.size, front_count, back_count, rest_present: rest_present)
                          .map { |offsets| offsets.map { |i| slot_type(elements, i, soften) } }
          # The end is clamped at the fronts, as {slot_offsets} clamps the backs: an unclamped negative end
          # (more back slots than elements) would count from the end instead. A range starting past the end
          # slices to `nil`.
          middle = elements[front_count...[elements.size - back_count, front_count].max] || []
          [fronts, rest_present ? Type::Combinator.tuple_of(*middle) : nil, backs]
        end

        # The element offsets a `[fronts, backs]` pair of fixed slots reads out of `size` elements: the
        # back slots follow the middle a rest absorbs, and follow the fronts directly without one. An
        # offset past `size` is a slot the source is too short to fill.
        def slot_offsets(size, front_count, back_count, rest_present:)
          back_start = rest_present ? [size - back_count, front_count].max : front_count
          [Array.new(front_count) { |i| i }, Array.new(back_count) { |i| back_start + i }]
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
        def slot_type(elements, index, soften)
          element = elements[index]
          return Type::Combinator.constant_of(nil) if element.nil?

          soften ? soften_optional_slot(element) : element
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

        # A per-element Array mark reaches a name only through a nested target: a name bound to a
        # whole literal array holds an Array, which is never `nil`. Nor does any mark reach a name bound
        # to an exact `nil` — a slot past a Tuple's end or a wrap's empty slot — which is `nil` whether
        # or not the source missed, so the mark could only withhold an honest verdict.
        def bind_target(target, type, optimistic, bindings, marked, context)
          return visit(target, type, optimistic, bindings, marked, context) if target.is_a?(Prism::MultiTargetNode)

          key = binding_key(target)
          bind_name(key, type, optimistic == true && !nil_literal?(type), bindings, marked) if key
        end

        # The rest is an `Array` even when the right-hand side is short, so it is never marked.
        def bind_rest_target(splat_node, type, bindings, marked)
          return unless splat_node.is_a?(Prism::SplatNode)

          key = binding_key(splat_node.expression)
          bind_name(key, type, false, bindings, marked) if key
        end

        # A named target's name, an index target's node (it binds no name, see {bind_name}), or nil for
        # a target that contributes nothing to the scope.
        def binding_key(target)
          case target
          when Prism::LocalVariableTargetNode, Prism::RequiredParameterNode, Prism::InstanceVariableTargetNode
            target.name
          when Prism::IndexTargetNode then target
          end
        end

        # A later binding of the same name (`a, a = ints`) wins, mark included. `name` is the
        # target node for an index target, which binds no name and so is never marked.
        def bind_name(name, type, optimistic, bindings, marked)
          bindings[name] = type
          marked.delete(name)
          marked << name if optimistic && name.is_a?(Symbol)
        end
      end
    end
  end
end
