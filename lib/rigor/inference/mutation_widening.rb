# frozen_string_literal: true

require_relative "../type"
require_relative "../source/node_children"

module Rigor
  module Inference
    # Widens a local- or instance-variable binding after a call whose receiver is that variable
    # AND whose method is a known in-place mutator.
    #
    # Closes the **G1 / G2** flow-folding gaps documented at
    # `docs/notes/20260521-mastodon-cluster4-flow-folding-triage.md` and queued in
    # [`docs/CURRENT_WORK.md`](../../../docs/CURRENT_WORK.md) § "Flow-folding". The user-visible
    # symptom they shared was a spurious `flow.always-truthy-condition` on a `arr.size == N` /
    # `arr.empty?` / `@arr.empty?` check that follows a loop body or sibling method that mutates
    # `arr` / `@arr` in place.
    #
    # **The mechanism.** When source like
    #
    #     arms = [first]                     # arms : Tuple[T]  (size=1)
    #     while peek_pipe?
    #       arms << next_arm                 # mutator call on a local
    #     end
    #     return arms.first if arms.size == 1
    #
    # runs through inference today, the literal `[first]` writes `arms` as `Tuple[T]`. The shape
    # carrier's `size` folds to `Constant[1]`. The body's `arms << next_arm` returns a type for
    # the call expression but does NOT rebind `arms`, so after the loop `arms` still carries the
    # `Tuple[T]` binding — `arms.size == 1` constant-folds to `true` and the user sees a false
    # `flow.always-truthy-condition`.
    #
    # The narrowest correct fix is to **widen the receiver binding at the mutator call site**:
    # replace `arms`'s binding with `Nominal[Array, [union(elements)]]` so the carrier no longer
    # carries the literal arity. Inside a loop body, the post-call body scope then joins with the
    # pre-loop scope through `join_with_nil_injection` → `Scope#join` (which unions per name); the
    # resulting union loses size precision, so the `arms.size` fold returns `Integer` (not
    # `Constant[1]`) and the diagnostic correctly stays silent.
    #
    # The widening is **always type-safe**: it never introduces a new fact, only forgets a
    # literal-shape fact that is no longer justified once mutation occurred. It costs only the
    # precise arity / pair-set the shape carrier was tracking; the underlying nominal stays exact
    # (`Array` / `Hash`) and element types stay as a union of what was there.
    #
    # **Scope.** This slice addresses:
    #
    # - `arr.<mutator>(...)` where `arr` is a local variable.
    # - `@arr.<mutator>(...)` where `@arr` is an instance variable.
    #
    # Out of scope (left for a separate cycle):
    #
    # - **`retry` flow edge** (e.g. `tries += 1; retry`). The `tries` rebind across `retry` is a
    #   flow-edge issue, not a call-site mutation issue.
    # - **Intervening method call invalidates the ivar binding** (e.g. `if @performed;
    #   perform!; if @performed`). The intra-procedural call effect on ivars is a separate
    #   mutation-effect feature.
    # - **Read-before-write nil** (e.g. `unless @warning_issued; ...; @warning_issued = true`).
    #   Requires tracking the first-write position; flow-sensitive but orthogonal.
    # - **Local-variable mutation inside a block body** (e.g. `arr = []; xs.each { |x| arr <<
    #   x }`) — landed as ADR-56 slice A (`widen_after_block`). **Ivar mutations inside a block
    #   ARE also handled** (ivars live in the method-body scope, not the block-local scope).
    #
    # The remaining three items above are demand-gated; see ADR-56.
    module MutationWidening
      # Array mutators that change either the size or the element set of a literal-shape carrier
      # (Tuple). Receiver-mutating methods only — non-mutating siblings (`map` vs `map!`,
      # `select` vs `select!`) stay precise.
      #
      # `<<` and `[]=` are the dominant survey cases; the bang variants and the size-mutators
      # cover the rest of the Mastodon cluster-4 G1 catalogue.
      ARRAY_MUTATORS = %i[
        << push append prepend unshift concat insert
        pop shift
        delete delete_at delete_if reject!
        clear compact!
        replace fill []=
        map! collect! select! filter! keep_if uniq!
        flatten! sort! sort_by! reverse! rotate! shuffle! slice!
      ].to_set.freeze

      # Hash mutators that invalidate a `HashShape` carrier. Same principle as `ARRAY_MUTATORS`:
      # only the receiver-mutating methods are listed.
      HASH_MUTATORS = %i[
        []= store
        delete delete_if reject! select! filter! keep_if
        clear compact! merge! update transform_keys! transform_values!
        replace
      ].to_set.freeze

      # Methods that return the receiver (or a shallow copy) and cannot mutate it. They must not
      # trigger widening or any other receiver-fact invalidation. The list is intentionally
      # narrow — only methods whose purity is unconditional and whose return value is the
      # receiver itself (or a copy that leaves the original untouched).
      PURE_SELF_RETURNERS = %i[freeze dup clone itself].freeze

      module_function

      # True when `method_name` is a pure self-returner that must
      # not invalidate the receiver's facts.
      def pure_self_returner?(method_name)
        PURE_SELF_RETURNERS.include?(method_name)
      end

      # Returns a scope with the call's receiver widened, when the receiver is a
      # local-/instance-variable read whose current binding is a literal-shape carrier
      # (`Tuple` / `HashShape`) AND the call name is a known in-place mutator for that shape.
      # Returns `current_scope` unchanged otherwise.
      #
      # @param call_node     [Prism::CallNode]
      # @param current_scope [Rigor::Scope]
      # @return              [Rigor::Scope]
      def widen_after_call(call_node:, current_scope:)
        return current_scope if pure_self_returner?(call_node.name)

        receiver = call_node.receiver
        return current_scope if receiver.nil?

        case receiver
        when Prism::LocalVariableReadNode
          widen_local(call_node.name, receiver.name, current_scope)
        when Prism::InstanceVariableReadNode
          widen_ivar(call_node.name, receiver.name, current_scope)
        else
          current_scope
        end
      end

      # Propagate block-body mutations of outer-scope variables back into `outer_scope`. Block
      # bodies live in a child scope; mutations the block body performs on captured outer
      # LOCALS are otherwise invisible to the post-call outer scope (ivars are handled correctly
      # already because they live in the method-body scope, not the block-local scope).
      #
      # Walks the block AST for `<receiver>.<method>(...)` calls whose receiver is either a
      # `LocalVariableReadNode` with `depth > 0` (a captured outer local — Prism's `depth`
      # counts scope hops outward; `depth == 0` means a block-local) or an
      # `InstanceVariableReadNode` (always method-scope), and applies `widen_after_call` for
      # each one against the outer scope. The widening is always safe — it can only LOSE
      # precision — so blindly propagating is sound regardless of whether the block actually
      # runs.
      #
      # Recurses into nested expression nodes so chained / nested forms (`arr << f(x); arr <<
      # g(y)`, `arr.push(x) if cond`) are all caught. Does NOT recurse into nested
      # `Prism::BlockNode`s — each block is processed by its own `eval_call`.
      def widen_after_block(call_node:, outer_scope:)
        block = call_node.block
        return outer_scope unless block.is_a?(Prism::BlockNode)

        body = block.body
        return outer_scope if body.nil?

        walk_for_outer_mutations(body, outer_scope)
      end

      def walk_for_outer_mutations(node, scope)
        return scope if node.nil?

        scope = widen_for_outer_receiver(node, scope) if node.is_a?(Prism::CallNode)

        # Descend into every child, including nested blocks. The `LocalVariableReadNode#depth`
        # check inside `widen_for_outer_receiver` keeps nested-block-locals from being widened
        # in the outer scope — only references with `depth >= 1` (true captures of the outer
        # scope's locals) trigger widening, so descending into nested blocks is safe and
        # necessary for the hkt_registry-shape case (an outer collection mutated inside an
        # iterator block whose body is itself inside another block).
        Source::NodeChildren.each_child(node) do |child|
          scope = walk_for_outer_mutations(child, scope)
        end
        scope
      end

      def widen_for_outer_receiver(call_node, scope)
        return scope if pure_self_returner?(call_node.name)

        receiver = call_node.receiver
        return scope if receiver.nil?

        case receiver
        when Prism::LocalVariableReadNode
          return scope if receiver.depth.zero?

          widen_local(call_node.name, receiver.name, scope)
        when Prism::InstanceVariableReadNode
          widen_ivar(call_node.name, receiver.name, scope)
        else
          scope
        end
      end

      def widen_local(method_name, var_name, current_scope)
        current = current_scope.local(var_name)
        widened = widen_for_mutator(current, method_name)
        return current_scope if widened.nil?

        current_scope.with_local(var_name, widened)
      end

      def widen_ivar(method_name, var_name, current_scope)
        current = current_scope.ivar(var_name)
        widened = widen_for_mutator(current, method_name)
        return current_scope if widened.nil?

        current_scope.with_ivar(var_name, widened)
      end

      # Returns the widened type for a binding whose receiver is about to be mutated by
      # `method_name`, or `nil` when no widening applies (binding is not a literal-shape
      # carrier, OR the method is not a mutator for that shape, OR the binding is already a
      # nominal — no precision to lose).
      def widen_for_mutator(type, method_name)
        return nil if type.nil?

        case type
        when Type::Tuple
          return nil unless ARRAY_MUTATORS.include?(method_name)

          widen_tuple(type)
        when Type::HashShape
          return nil unless HASH_MUTATORS.include?(method_name)

          widen_hash_shape(type)
        end
      end

      # `Tuple[A, B, C]` → `Nominal[Array, [union(A, B, C)]]`. An empty tuple has no element
      # evidence, so the widened form carries `untyped` element bound — matches the
      # `tuple_to_array` widening already used by `BlockFolding`.
      def widen_tuple(tuple)
        element_type =
          if tuple.elements.empty?
            Type::Combinator.untyped
          elsif tuple.elements.size == 1
            tuple.elements.first
          else
            Type::Combinator.union(*tuple.elements)
          end
        Type::Combinator.nominal_of("Array", type_args: [element_type])
      end

      # `HashShape` (closed or open) → `Nominal[Hash, [Kunion, Vunion]]`. Empty / extra-keys-only
      # shapes degrade to a fully-untyped Hash.
      def widen_hash_shape(shape)
        if shape.pairs.empty?
          return Type::Combinator.nominal_of("Hash",
                                             type_args: [Type::Combinator.untyped,
                                                         Type::Combinator.untyped])
        end

        key_type = key_union_for(shape.pairs.keys)
        value_type = Type::Combinator.union(*shape.pairs.values)
        Type::Combinator.nominal_of("Hash", type_args: [key_type, value_type])
      end

      # Maps the literal Ruby key set (`Symbol` / `String`) to a union of the corresponding type
      # carriers. We deliberately do NOT fold to a `Constant<:k1> | Constant<:k2>` union — that
      # would be a precision improvement that complicates the widening contract; the goal here
      # is to LOSE precision, not to record a new fact set.
      def key_union_for(keys)
        kinds = keys.map { |k| k.is_a?(Symbol) ? "Symbol" : "String" }.uniq
        carriers = kinds.map { |name| Type::Combinator.nominal_of(name) }
        carriers.size == 1 ? carriers.first : Type::Combinator.union(*carriers)
      end

      # ----------------------------------------------------------------
      # ADR-56 slice C — receiver-content element-type JOIN.
      #
      # `widen_after_block` above forgets a literal-shape carrier's arity when a captured local
      # is content-mutated inside a block, but it keeps only the SEED's element types — an
      # unsound under-approximation for a non-empty seed (`out = [0]; arr.each { |x| out << x
      # }` types `Array[0]` while the runtime array is `[0, 1, 2, 3]`). Slice C joins the
      # appended/stored element (and key/value) types INTO the continuation collection's
      # parameter, so the result is `Array[0 | Integer]` rather than `Array[0]`.
      #
      # Array content-mutators that append/store ELEMENTS. The appended element type is the
      # call's argument type(s); `[]=`'s value is its LAST argument (the keys precede it).
      # Subset of `ARRAY_MUTATORS`: only the element-INTRODUCING methods (removers / reorderers
      # add no new element evidence and are already covered by the arity-forget).
      ARRAY_CONTENT_ADDERS = %i[
        << push append prepend unshift concat insert []= fill replace
      ].to_set.freeze

      # Hash content-mutators that store a key→value pair. For `[]=` / `store` the key is the
      # first argument and the value the last.
      HASH_CONTENT_ADDERS = %i[[]= store].to_set.freeze

      # String content-mutators that append to the buffer. String carries no element parameter,
      # so these contribute nothing to a join — they are listed so the orchestrator recognises
      # them as content mutators (the binding already widens to `String` via normal typing);
      # the join helpers below short-circuit on a non-collection pre-state.
      STRING_CONTENT_ADDERS = %i[<< concat prepend insert replace].to_set.freeze

      # Every method name that mutates a captured local's CONTENT — the union the orchestrator
      # scans the block body for.
      CONTENT_ADDERS = (ARRAY_CONTENT_ADDERS | HASH_CONTENT_ADDERS | STRING_CONTENT_ADDERS).freeze

      # The element types a single content-mutator call introduces into an Array, given the
      # per-argument types (already typed in the block body scope). `concat`/`replace` take
      # collection arguments, so their element evidence is the arguments' OWN element types
      # unioned; the rest append the argument values directly. Returns `[]` when no element
      # evidence (e.g. a `<<` with no resolvable arg).
      def array_added_elements(method_name, arg_types)
        return [] if arg_types.empty?

        case method_name
        when :concat, :replace
          arg_types.flat_map { |t| collection_element_types(t) }
        when :insert
          # `insert(index, *objs)` — first arg is the position.
          arg_types.drop(1)
        when :[]=
          # `arr[i] = v` / `arr[i, n] = v` — value is the last argument.
          [arg_types.last]
        when :fill
          # `fill(value)` — only the no-block single-value form adds a
          # concrete element; block / range forms are conservatively
          # ignored (the arity-forget already widened the binding).
          arg_types.size == 1 ? arg_types : []
        else # << push append prepend unshift
          arg_types
        end
      end

      # Builds the continuation Array type from the pre-state binding and the appended element
      # types. The floor is `Array[Dynamic[top]]` (the sound empty-seed behaviour) when there is
      # no element evidence at all.
      def join_array_content(pre_state, added_elements)
        seed_elements = collection_element_types(pre_state)
        added = added_elements.compact
        # The empty-seed floor element is `Dynamic[top]` (no element evidence). When real
        # appended evidence exists that floor carries nothing, so drop it — an empty accumulator
        # built by `out << x*2` reads `Array[Integer]`, not `Array[Integer | Dynamic[top]]`.
        seed_elements = drop_dynamic(seed_elements) unless added.empty?
        elements = seed_elements + added
        return Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.untyped]) if elements.empty?

        Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.union(*elements)])
      end

      # Builds the continuation Hash type from the pre-state binding and a list of `[key_type,
      # value_type]` pairs stored by `[]=` / `store`.
      def join_hash_content(pre_state, added_pairs)
        seed_keys, seed_values = hash_shape_key_values(pre_state)
        added_keys = added_pairs.map(&:first).compact
        added_values = added_pairs.map(&:last).compact
        seed_keys = drop_dynamic(seed_keys) unless added_keys.empty?
        seed_values = drop_dynamic(seed_values) unless added_values.empty?
        keys = seed_keys + added_keys
        values = seed_values + added_values
        key_t = keys.empty? ? Type::Combinator.untyped : Type::Combinator.union(*keys)
        value_t = values.empty? ? Type::Combinator.untyped : Type::Combinator.union(*values)
        Type::Combinator.nominal_of("Hash", type_args: [key_t, value_t])
      end

      # Drops `Dynamic` (incl. `untyped`) constituents from a type list.
      def drop_dynamic(types)
        types.grep_v(Type::Dynamic)
      end

      # Element types carried by a collection binding, regardless of which carrier holds them: a
      # `Tuple` lists them, a `Nominal[Array, [E]]` has one element param, a bare `Array` /
      # anything else yields none.
      def collection_element_types(type)
        case type
        when Type::Tuple
          type.elements
        when Type::Nominal
          type.class_name == "Array" ? type.type_args : []
        when Type::Union
          # A loop's single-pass join can union the widened collection with its un-widened
          # literal seed (`Array[0] | [0]`); pull element evidence from every Array-ish member.
          type.members.flat_map { |m| collection_element_types(m) }
        else
          []
        end
      end

      # `[keys, values]` evidence from a Hash-ish pre-state binding — a `HashShape` (literal
      # pairs) or a `Nominal[Hash, [K, V]]`.
      def hash_shape_key_values(type)
        case type
        when Type::HashShape
          return [[], []] if type.pairs.empty?

          [[key_union_for(type.pairs.keys)], type.pairs.values]
        when Type::Nominal
          type.class_name == "Hash" && type.type_args.size == 2 ? [[type.type_args[0]], [type.type_args[1]]] : [[], []]
        when Type::Union
          type.members.each_with_object([[], []]) do |m, (ks, vs)|
            mk, mv = hash_shape_key_values(m)
            ks.concat(mk)
            vs.concat(mv)
          end
        else
          [[], []]
        end
      end
    end
  end
end
