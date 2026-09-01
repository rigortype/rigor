# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Inference
    # The element / key / value **content join** shared by every path that observes a collection
    # being content-mutated in place.
    #
    # {MutationWidening} forgets what a mutation falsified — a literal's arity, and (for a
    # slot-rewriting mutator) its value pinning. That half only ever subtracts. This module is the
    # other half: it adds back what the mutation is known to have PUT in the collection, so the
    # continuation carrier covers the mutated contents instead of only the seed's.
    #
    # Two callers share it, and they must agree:
    #
    # - the **block-capture** path (ADR-56 slice C) — `out = [0]; xs.each { |x| out << x }` types
    #   `out` as `Array[0 | Integer]`, not `Array[0]`;
    # - the **straight-line** path (issue #560) — `u = [1, 2]; u.push(6)` types `u` as
    #   `Array[1 | 2 | Integer]`, not `Array[1 | 2]`. Before the join, `u.last` read back `1 | 2`,
    #   the constant-comparison fold turned `u.last == 6` into `Constant[false]`, and a correct
    #   program drew a false `flow.always-truthy-condition`. `mail`'s ragel tables are the same root
    #   seen from the precision side: `stack = []; stack[top] = cs` widened to `Array[untyped]`
    #   where the join reads `Array[Integer]` (issue #533 item 8).
    module ContentJoin
      # Array content-mutators that append/store ELEMENTS. The appended element type is the call's
      # argument type(s); `[]=`'s value is its LAST argument (the keys precede it). Subset of
      # {MutationWidening::ARRAY_MUTATORS}: only the element-INTRODUCING methods (removers /
      # reorderers add no new element evidence and are already covered by the arity-forget).
      ARRAY_CONTENT_ADDERS = %i[
        << push append prepend unshift concat insert []= fill replace
      ].to_set.freeze

      # Hash content-mutators that store a key→value pair. For `[]=` / `store` the key is the first
      # argument and the value the last.
      HASH_CONTENT_ADDERS = %i[[]= store].to_set.freeze

      # String content-mutators that append to the buffer. String carries no element parameter, so
      # these contribute nothing to a join — they are listed so the orchestrator recognises them as
      # content mutators (the binding already widens to `String` via normal typing); the join
      # helpers below short-circuit on a non-collection pre-state.
      STRING_CONTENT_ADDERS = %i[<< concat prepend insert replace].to_set.freeze

      # Every method name that mutates a collection's CONTENT — the union the orchestrators scan a
      # block body for, and the gate the straight-line path types its arguments behind.
      CONTENT_ADDERS = (ARRAY_CONTENT_ADDERS | HASH_CONTENT_ADDERS | STRING_CONTENT_ADDERS).freeze

      module_function

      # The element types a single content-mutator call introduces into an Array, given the
      # per-argument types (already typed by the caller in the scope the arguments are evaluated
      # in). `concat`/`replace` take collection arguments, so their element evidence is the
      # arguments' OWN element types unioned; the rest append the argument values directly. Returns
      # `[]` when there is no element evidence (e.g. a `<<` with no resolvable arg).
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
          #
          # The SPLICE forms (`arr[i, n] = other` / `arr[range] = other`) store `other`'s ELEMENTS,
          # not `other` itself, so reading the value as one element over-widens: `a[0, 2] = [1, 2]`
          # contributes `Array[Integer]` where `Integer` is the truth. Left alone deliberately —
          # the answer is a superset either way, so it can only cost precision, and splitting the
          # arities here would need the receiver's own element type to unwrap against. Revisit if a
          # corpus site ever reads an element back through a splice-built array.
          [arg_types.last]
        when :fill
          # `fill(value)` — only the no-block single-value form adds a concrete element; block /
          # range forms are conservatively ignored (the arity-forget already widened the binding).
          arg_types.size == 1 ? arg_types : []
        else # << push append prepend unshift
          arg_types
        end
      end

      # Builds the continuation Array type from the pre-state binding and the appended element
      # types. The floor is `Array[Dynamic[top]]` (the sound empty-seed behaviour) when there is no
      # element evidence at all.
      def join_array_content(pre_state, added_elements)
        seed_elements = collection_element_types(pre_state)
        added = added_elements.compact
        # The empty-seed floor element is `Dynamic[top]` (no element evidence). When real appended
        # evidence exists that floor carries nothing, so drop it — an empty accumulator built by
        # `out << x*2` reads `Array[Integer]`, not `Array[Integer | Dynamic[top]]`.
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

      # ----------------------------------------------------------------
      # Seed-admissibility — the straight-line join's signature gate (issue #560).
      #
      # A join is not free: it grows the carrier's element union, and a carrier that grows a member
      # the enclosing method's HAND-WRITTEN signature does not admit turns a correct program into a
      # `def.return-type-mismatch`. haml's temple builders are the corpus shape —
      #
      #     def compile_html(node)          # sig: (untyped) -> Array[:multi]
      #       temple = [:multi]
      #       temple << [:static, "<style>\n"]
      #       temple
      #     end
      #
      # — where joining the appended tuple precisely reads `Array[:multi | [:static, String]]` and
      # draws a mismatch against `Array[:multi]` on eight sites. (PR #561 hit the same wall from the
      # other direction and had to scope value-pin widening away from adders to avoid it.) A gradual
      # member does NOT rescue that: `Array[:multi | [:static, String] | untyped]` is still rejected,
      # because every non-`Dynamic` member is judged on its own. The gate is what keeps the foreign
      # member out; the caller's gradual floor is a separate concern and neither substitutes for the
      # other.
      #
      # So added evidence is admitted per member, against the class set the SEED already carries:
      #
      # - the seed's class set already admits the added member's class — the collection is
      #   homogeneous in the sense that matters, and the member joins as itself
      #   (`u = [1, 2]; u.push(6)` contributes `Integer`);
      # - it does not — the collection is provably heterogeneous, and between the literal seed and
      #   the author's signature the engine has no ground to adjudicate. It contributes
      #   `Dynamic[top]` instead of a foreign precise member;
      # - the seed carries nothing to contradict — an empty literal, or a slot the engine cannot type
      #   — and every member is admitted as itself.
      #
      # The second case only ever replaces a WRONG precise element type with a gradual one, so it is
      # a soundness improvement paid for in opacity on exactly the sites that were lying.
      #
      # What this module does NOT decide is whether the resulting parameter may be CLOSED. That is
      # the caller's call, and it turns on whether the caller saw every store —
      # {MutationWidening#join_added_elements} carries the rule and the counter-example.

      # `added`, with every member the seed's class set does not admit replaced by `Dynamic[top]`.
      #
      # A seed that carries nothing to contradict admits everything: an empty literal has no class
      # set, and a `Dynamic` member means the engine could not type that slot, so it cannot rule
      # anything out either.
      #
      # Both sides are flattened through their `Union` members before matching. Judging a union
      # wholesale would floor `["a", 1]`-shaped evidence against an `Integer` seed even though its
      # `Integer` half is admissible, and `evidence_class` has no answer for a `Union` at all — so
      # the wholesale reading is strictly worse and no simpler.
      def admissible_evidence(seed_members, added)
        members = seed_members.flat_map { |m| union_members(m) }
        return added if members.empty? || members.any?(Type::Dynamic)

        classes = members.filter_map { |m| evidence_class(m) }.to_set
        added.flat_map { |type| admit_members(union_members(type), classes) }
      end

      # Each member of one added type, kept when its class is admitted and floored when it is not.
      # A type whose members are all admitted returns them unchanged, so the common single-member
      # case is `[type]`.
      def admit_members(members, classes)
        members.map { |m| classes.include?(evidence_class(m)) ? m : Type::Combinator.untyped }
      end

      # The class name a type carrier commits its values to, or `nil` when it commits to none. A
      # `nil` answer is never admitted: an unnameable carrier cannot be shown compatible with the
      # seed, so it takes the gradual floor.
      def evidence_class(type)
        case type
        when Type::Nominal then type.class_name
        when Type::Constant then type.value.class.name
        when Type::Tuple then "Array"
        when Type::HashShape then "Hash"
        end
      end

      def union_members(type)
        type.is_a?(Type::Union) ? type.members : [type]
      end

      # Drops `Dynamic` (incl. `untyped`) constituents from a type list, INCLUDING the ones sitting
      # inside a `Union` member — a `Dynamic` is a constituent wherever it sits, which is what this
      # helper's callers have always meant by the word.
      #
      # The nesting is not hypothetical: a straight-line join floors its result (it saw one store,
      # see {MutationWidening#gradual_floor}), so an accumulator mutated inside a loop reaches the
      # slice-C re-derivation as `Array[Dynamic[top] | Integer]` rather than the bare
      # `Array[Dynamic[top]]` it used to. A `grep_v` cannot see that, and ADR-56's own `acc = [];
      # while …; acc.push(m); end` → `Array[Integer]` silently became `Array[Dynamic[top] |
      # Integer]`. Discarding it is exactly right at THIS seam: the block and loop paths scan the
      # whole body and join every store in it, so their evidence is complete and the straight-line
      # path's admission of incompleteness no longer applies.
      def drop_dynamic(types)
        types.flat_map { |type| union_members(type) }.grep_v(Type::Dynamic)
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
          # A loop's single-pass join can union the widened collection with its un-widened literal
          # seed (`Array[0] | [0]`); pull element evidence from every Array-ish member.
          type.members.flat_map { |m| collection_element_types(m) }
        else
          []
        end
      end

      # `[keys, values]` evidence from a Hash-ish pre-state binding — a `HashShape` (literal pairs)
      # or a `Nominal[Hash, [K, V]]`.
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

      # Maps a literal Ruby key set to a union of the corresponding type carriers. Symbol / String /
      # Integer / Float keys widen to their class nominal; the `true` / `false` / `nil` singleton
      # keys keep their constant carrier (the constant IS the class's whole value set, and `nil`
      # reads better than `NilClass` in a widened `Hash[K, V]`). We deliberately do NOT fold the
      # widenable kinds to a `Constant<:k1> | Constant<:k2>` union — that would be a precision
      # improvement that complicates the widening contract; the goal there is to LOSE precision, not
      # to record a new fact set.
      def key_union_for(keys)
        carriers = keys.map do |key|
          next Type::Combinator.constant_of(key) if [true, false, nil].include?(key)

          Type::Combinator.nominal_of(key.class.name)
        end.uniq
        carriers.size == 1 ? carriers.first : Type::Combinator.union(*carriers)
      end
    end
  end
end
