# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "../source/node_children"
require_relative "content_join"
require_relative "receiver_alias"

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
    # - a receiver that *selects* among such variables rather than naming one —
    #   `(kind == :required ? required : optional)[key] = info`, an `if`/`else`, `||` / `&&`. Every
    #   variable the expression can evaluate to is a possible mutation target, so every one widens
    #   (issue #277). See {ReceiverAlias}.
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

      # Returns a scope with the call's receiver widened, for every variable the receiver expression
      # can evaluate to ({ReceiverAlias.candidates}) whose current binding is a literal-shape carrier
      # (`Tuple` / `HashShape`) or an empty-witness refinement (`non-empty-array` /
      # `non-empty-hash`) AND whose call name is a known in-place mutator for that shape.
      # Returns `current_scope` unchanged otherwise.
      #
      # `arg_types` carries the mutator call's argument types, already typed by the caller in the
      # scope the arguments are evaluated in. They are what the widened carrier JOINS its added
      # content evidence from (issue #560); an empty list means "no evidence", which reproduces the
      # pre-join behaviour exactly.
      NO_ARG_TYPES = [].freeze

      # @param call_node     [Prism::CallNode]
      # @param current_scope [Rigor::Scope]
      # @param arg_types     [Array<Rigor::Type::Base>]
      # @return              [Rigor::Scope]
      def widen_after_call(call_node:, current_scope:, arg_types: NO_ARG_TYPES)
        return current_scope if pure_self_returner?(call_node.name)

        widen_receiver_aliases(call_node.receiver, call_node.name, current_scope, arg_types: arg_types)
      end

      # True when `receiver` names at least one variable whose CURRENT binding is a literal-shape
      # carrier — the only pre-state {#widen_for_mutator} joins into. Callers use it to skip typing a
      # mutator's arguments when nothing will consume them: `buf << x` on a String and `arr << x` on an
      # already-nominal Array are the common cases, and `Scope#type_of` memoizes nothing.
      def joinable_receiver?(receiver, scope)
        return false if receiver.nil?

        ReceiverAlias.candidates(receiver).any? do |read|
          current =
            case read
            when Prism::LocalVariableReadNode then scope.local(read.name)
            when Prism::InstanceVariableReadNode then scope.ivar(read.name)
            end
          current.is_a?(Type::Tuple) || current.is_a?(Type::HashShape)
        end
      end

      # Widens every variable `receiver` can evaluate to, against `method_name`'s mutator table.
      def widen_receiver_aliases(receiver, method_name, current_scope, arg_types: NO_ARG_TYPES)
        return current_scope if receiver.nil?

        ReceiverAlias.candidates(receiver).reduce(current_scope) do |acc, read|
          widen_alias_read(method_name, read, acc, arg_types: arg_types)
        end
      end

      # Propagate block-body mutations of outer-scope variables back into `outer_scope`. Block
      # bodies live in a child scope; mutations the block body performs on captured outer
      # LOCALS are otherwise invisible to the post-call outer scope (ivars are handled correctly
      # already because they live in the method-body scope, not the block-local scope).
      #
      # Walks the block AST for `<receiver>.<method>(...)` calls, resolves the receiver expression
      # to the variables it can evaluate to ({ReceiverAlias.candidates}), and widens each one
      # against the outer scope. A `LocalVariableReadNode` with `depth == 0` is skipped — Prism's
      # `depth` counts scope hops outward, so `0` means a block-local, not a capture; an
      # `InstanceVariableReadNode` is always method-scope and always applies. The widening is
      # always safe — it can only LOSE precision — so blindly propagating is sound regardless of
      # whether the block actually runs.
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
        node.rigor_each_child do |child|
          scope = walk_for_outer_mutations(child, scope)
        end
        scope
      end

      def widen_for_outer_receiver(call_node, scope)
        return scope if pure_self_returner?(call_node.name)

        receiver = call_node.receiver
        return scope if receiver.nil?

        ReceiverAlias.candidates(receiver).reduce(scope) do |acc, read|
          # A block-local read (`depth == 0`) is not a capture of the outer scope, so widening its
          # name against the OUTER scope would hit an unrelated same-named binding.
          next acc if read.is_a?(Prism::LocalVariableReadNode) && read.depth.zero?

          # `values: :keep` — this is the block-capture path, and the slice-C content join that runs
          # after it re-adds the appended values' types onto the widened seed, so the seed's own value
          # pinning is still justified (`out = [0]; arr.each { out << x }` never rewrites slot 0). The
          # straight-line paths have no such join, which is why their default is `:widen` (issue #560).
          widen_alias_read(call_node.name, read, acc, values: :keep)
        end
      end

      def widen_alias_read(method_name, read, scope, values: :widen, arg_types: NO_ARG_TYPES)
        case read
        when Prism::LocalVariableReadNode
          widen_local(method_name, read.name, scope, values: values, arg_types: arg_types)
        when Prism::InstanceVariableReadNode
          widen_ivar(method_name, read.name, scope, values: values, arg_types: arg_types)
        else scope
        end
      end

      def widen_local(method_name, var_name, current_scope, values: :widen, arg_types: NO_ARG_TYPES)
        current = current_scope.local(var_name)
        widened = widen_for_mutator(current, method_name, values: values, arg_types: arg_types)
        return current_scope if widened.nil?

        current_scope.with_local(var_name, widened)
      end

      def widen_ivar(method_name, var_name, current_scope, values: :widen, arg_types: NO_ARG_TYPES)
        current = current_scope.ivar(var_name)
        widened = widen_for_mutator(current, method_name, values: values, arg_types: arg_types)
        return current_scope if widened.nil?

        current_scope.with_ivar(var_name, widened)
      end

      # Mutators that can land a NEW value in an EXISTING slot, falsifying that slot's value pinning
      # (`t[0] += 5` holds 6 where `Constant[1]` was — issue #560). Adders, removers, and reorderers
      # leave every surviving slot's value intact, so their widening keeps the pinning; what an ADDER
      # introduces is covered by the {#join_added_elements} join instead, which is why widening the
      # SEED's pinning under `<<` (the shape haml's hand-written sigs pin) is not needed either.
      VALUE_REWRITING_MUTATORS = %i[[]= fill map! collect! replace store merge! update transform_values!].to_set.freeze
      private_constant :VALUE_REWRITING_MUTATORS

      # Returns the widened type for a binding whose receiver is about to be mutated by
      # `method_name`, or `nil` when no widening applies (binding is not a literal-shape
      # carrier, OR the method is not a mutator for that shape, OR the binding is already a
      # nominal — no precision to lose).
      def widen_for_mutator(type, method_name, values: :widen, arg_types: NO_ARG_TYPES)
        values = :keep unless VALUE_REWRITING_MUTATORS.include?(method_name)

        return nil if type.nil?

        case type
        when Type::Tuple
          return nil unless ARRAY_MUTATORS.include?(method_name)

          join_added_elements(widen_tuple(type, values: values), method_name, arg_types, type.elements)
        when Type::HashShape
          return nil unless HASH_MUTATORS.include?(method_name)

          join_added_pairs(widen_hash_shape(type, values: values), method_name, arg_types,
                           ContentJoin.hash_shape_key_values(type))
        when Type::Difference
          widen_difference(type, method_name)
        end
      end

      # Joins the element evidence the mutator's own ARGUMENTS introduce into the already-widened
      # Array carrier (issue #560). Without it the widening keeps only the SEED's elements, which
      # under-covers precisely the value the mutation added: `u = [1, 2]; u.push(6)` left
      # `Array[1 | 2]`, so `u.last == 6` constant-folded to false and fired a false always-falsey on
      # correct code. {ContentJoin} owns the algebra — including the seed-admissibility gate that
      # keeps a heterogeneous accumulator from growing a member a hand-written signature rejects.
      #
      # The added evidence is **value-pin widened** first, so the join never manufactures a NEW
      # constant fold in place of the one it removes: `opts[:mode] = :fast` must not leave
      # `Constant[:fast]` as the whole value bound and let a later `opts[:mode] == :fast` fold to
      # `Constant[true]` — that would trade an always-falsey FP for an always-truthy one on the same
      # shape. Widening it is also what makes the seed's class set the right admissibility test.
      #
      # Non-adders (removers, reorderers) introduce no element evidence and return the widened
      # carrier untouched.
      #
      # `seed_elements` is the PRE-STATE literal's own element list, not the widened carrier's —
      # {ContentJoin.admissible_evidence} explains why the two are not interchangeable.
      def join_added_elements(widened, method_name, arg_types, seed_elements)
        return widened unless ContentJoin::ARRAY_CONTENT_ADDERS.include?(method_name)

        added = value_pin_widened(ContentJoin.array_added_elements(method_name, arg_types))
        return widened if added.empty?

        ContentJoin.join_array_content(widened, ContentJoin.admissible_evidence(seed_elements, added))
      end

      # The Hash-side twin of {#join_added_elements}: `h[k] = v` / `h.store(k, v)` join the stored
      # key and value into the widened `Hash[K, V]` carrier, each admitted against its OWN side's
      # seed evidence (a foreign key does not make the value gradual, or the reverse).
      def join_added_pairs(widened, method_name, arg_types, seed_pairs)
        return widened unless ContentJoin::HASH_CONTENT_ADDERS.include?(method_name)
        return widened if arg_types.size < 2

        added = value_pin_widened([arg_types.first, arg_types.last])
        return widened unless added.size == 2

        seed_keys, seed_values = seed_pairs
        key = admitted_union(seed_keys, added.first)
        value = admitted_union(seed_values, added.last)
        ContentJoin.join_hash_content(widened, [[key, value]])
      end

      # One carrier for a stored key or value. A `Hash` pair has a single slot per side, so the
      # admissible list — which is two members when the seed's own evidence is gradual — folds to a
      # union rather than being truncated.
      def admitted_union(seed_members, added)
        admitted = ContentJoin.admissible_evidence(seed_members, [added])
        admitted.size == 1 ? admitted.first : Type::Combinator.union(*admitted)
      end

      # Normalizes the types the mutator's arguments contribute, before they join.
      #
      # `widen_value_pinned` erases a constant's VALUE. A stored literal collection needs the same
      # treatment for its literal SHAPE, and for the same reason one step removed: the program keeps
      # a reference to what it stored and mutates it through the slot —
      #
      #     params[:f] ||= []
      #     params[:f] << :status
      #
      # is Redmine's `Query#as_params` idiom, six times over. The `<<` mutates the nested array, and
      # nothing writes that back through the outer Hash's value parameter, so joining the literal
      # `Tuple[]` would pin `Hash[Symbol, []]` on a hash whose slot really holds `[:status]` — a
      # WRONG precise type, and `params[:f].empty?` would fold to `true` off it. That is the same
      # class of stale fold this whole change exists to remove, so the shape goes with the value:
      # `[]` joins as `Array[untyped]`, `{}` as `Hash[untyped, untyped]`. Both are true of the slot
      # no matter what the program does to the object afterwards.
      def value_pin_widened(types)
        types.compact.map { |type| shape_erased(Type::Combinator.widen_value_pinned(type)) }
      end

      def shape_erased(type)
        case type
        when Type::Tuple then widen_tuple(type, values: :widen)
        when Type::HashShape then widen_hash_shape(type, values: :widen)
        else type
        end
      end

      # `non-empty-array[T]` / `non-empty-hash[K, V]` → the bare base nominal. These refinement
      # carriers are what `empty?` / `any?` narrowing writes (ADR-47 §4-4), and they are just as
      # invalidated by an in-place mutator as a `Tuple` is: `arr.clear` makes `arr` empty, so a
      # surviving `Difference[Array[T], Tuple[]]` would project `arr.size` to `positive-int` and
      # fold `arr.size == 0` to `Constant[false]` — a false `flow.always-falsey-condition` on
      # correct code.
      #
      # Only the EMPTY-witness differences over Array / Hash are widened, and only for that
      # base's mutator table. The other catalogued refinements are unreachable from these tables
      # by construction: `non-empty-string` and `non-zero-int` bind String / Integer receivers,
      # whose mutators (`String#<<` and friends) appear in neither `ARRAY_MUTATORS` nor
      # `HASH_MUTATORS` — and none of them can empty a non-empty string anyway.
      def widen_difference(difference, method_name)
        return nil unless difference.removes_empty_witness?

        base = difference.base
        case base.class_name
        when "Array" then ARRAY_MUTATORS.include?(method_name) ? base : nil
        when "Hash" then HASH_MUTATORS.include?(method_name) ? base : nil
        end
      end

      # `Tuple[A, B, C]` → `Nominal[Array, [union(A, B, C)]]`; under `values: :widen`, each element's
      # VALUE pinning widens to its class nominal (`1 | 2` → `Integer`): a slot-rewriting mutator
      # falsifies values along with the shape — `t = [1, 2]; t[0] += 5` holds `6` at slot 0, so a
      # surviving `Array[1 | 2]` feeds the constant-comparison fold and fires a false always-falsey
      # on `t[0] == 6` (issue #560). An empty tuple has no element evidence, so the widened form
      # carries `untyped` element bound — matches `BlockFolding`'s `tuple_to_array` widening.
      def widen_tuple(tuple, values: :widen)
        element_type =
          if tuple.elements.empty?
            Type::Combinator.untyped
          else
            elements = tuple.elements
            elements = elements.map { |e| Type::Combinator.widen_value_pinned(e) } if values == :widen
            elements.size == 1 ? elements.first : Type::Combinator.union(*elements)
          end
        Type::Combinator.nominal_of("Array", type_args: [element_type])
      end

      # `HashShape` (closed or open) → `Nominal[Hash, [Kunion, Vunion]]`. Empty / extra-keys-only
      # shapes degrade to a fully-untyped Hash. Values widen their pinning the same way
      # {#widen_tuple}'s elements do (issue #560): `opts = {headers: false}` then
      # `opts[:encoding] = v` must not keep `false` as the whole value bound — redmine's
      # `import.rb:274` read the stored key back through it and drew a false always-falsey.
      def widen_hash_shape(shape, values: :widen)
        if shape.pairs.empty?
          return Type::Combinator.nominal_of("Hash",
                                             type_args: [Type::Combinator.untyped,
                                                         Type::Combinator.untyped])
        end

        key_type = key_union_for(shape.pairs.keys)
        value_types = shape.pairs.values
        value_types = value_types.map { |v| Type::Combinator.widen_value_pinned(v) } if values == :widen
        Type::Combinator.nominal_of("Hash", type_args: [key_type, Type::Combinator.union(*value_types)])
      end

      # ADR-56 slice C's content JOIN — the other half of this module — lives in {ContentJoin}, which
      # both the block-capture path and the straight-line path above share.
      #
      # `key_union_for` is delegated rather than duplicated: {#widen_hash_shape} and
      # `ContentJoin.hash_shape_key_values` must map a literal key set the SAME way, or a widened
      # carrier and the join that reads it back disagree about the key parameter.
      def key_union_for(keys)
        ContentJoin.key_union_for(keys)
      end
    end
  end
end
