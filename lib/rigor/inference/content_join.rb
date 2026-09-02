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
      #
      # **Every arm the seed carries survives, a `Dynamic` arm included.** A gradual seed element is
      # a statement about what the collection ALREADY holds — a parameter declared `Array[untyped]`,
      # a local seeded from a call whose signature returns the same, a literal `[x]` whose slot the
      # engine could not type — and the stores a body adds are evidence about what the body put in,
      # never about what was there first. Dropping the
      # arm once concrete evidence appeared closed a declared `Array[untyped]` parameter to
      # `Array[Integer]` under `[1, 2].each { a.push(rand(9)) }` and drew `undefined method 'upcase'`
      # on `a.first.upcase`, which the declaration licenses (issue #586).
      #
      # What this method therefore never sees is the arity-forget's OWN floor: `widen_tuple` spells
      # an empty `[]` as `Array[untyped]`, and read back through here that `untyped` would be
      # indistinguishable from a declared one. Each caller keeps that floor out at its source by
      # reading the seed from before the widening ran — the block seam from the pre-widen scope, the
      # loop seam from the pre-body scope — so an empty literal contributes no element and `out = [];
      # xs.each { out << x*2 }` still reads `Array[Integer]`. The straight-line seam passes the
      # widened carrier, and adds the same `Dynamic` as its one-store floor anyway.
      #
      # **The rederived carrier replaces only the members it stands for** — see {#array_residue}.
      def join_array_content(pre_state, added_elements)
        elements = collection_element_types(pre_state) + added_elements.compact
        element_t = elements.empty? ? Type::Combinator.untyped : Type::Combinator.union(*elements)
        with_residue(Type::Combinator.nominal_of("Array", type_args: [element_t]), array_residue(pre_state))
      end

      # Builds the continuation Hash type from the pre-state binding and a list of `[key_type,
      # value_type]` pairs stored by `[]=` / `store`. The seed's key and value arms survive on the
      # same terms as {#join_array_content}'s elements: a declared `Hash[untyped, untyped]` stays
      # gradual on both sides however many pairs the body stores, and a pre-state member that is not
      # a Hash carrier at all survives whole ({#hash_residue}).
      def join_hash_content(pre_state, added_pairs)
        seed_keys, seed_values = hash_shape_key_values(pre_state)
        keys = seed_keys + added_pairs.map(&:first).compact
        values = seed_values + added_pairs.map(&:last).compact
        key_t = keys.empty? ? Type::Combinator.untyped : Type::Combinator.union(*keys)
        value_t = values.empty? ? Type::Combinator.untyped : Type::Combinator.union(*values)
        with_residue(Type::Combinator.nominal_of("Hash", type_args: [key_t, value_t]), hash_residue(pre_state))
      end

      # ----------------------------------------------------------------
      # Union residue — the members the rederived carrier does NOT stand for (issue #631).
      #
      # A join REPLACES the binding with one freshly built `Nominal`, and that is the right answer
      # only for the pre-state members the mutation actually applied to as a collection of that
      # class. A `Union` seed can carry members that are not collection carriers at all, and those
      # contribute no element / key / value evidence — `collection_element_types` and
      # `hash_shape_key_values` both answer "nothing" for them. Before this rule they were simply
      # gone:
      #
      #     out = flag ? u : [2]     # Dynamic[top] | [2]
      #     [1].each { out << 2 }    # -> Array[2]; the whole-variable Dynamic arm dropped
      #     out.first.upcase         # undefined method `upcase' for 2 -- on correct code
      #
      # This is WD2.9's rule ("a seed's own gradual arm survives the rederivation") one level out:
      # there the surviving `Dynamic` was an ELEMENT of an Array carrier, here it is the whole
      # variable. Both say the same thing — the body's stores are evidence about what the body put
      # in, never about what the variable WAS — and the straight-line seam already reads the union
      # through untouched, so the block and loop seams were the outliers.
      #
      # A member survives whole; it is never re-examined for element evidence, so nothing is
      # double-counted. `Array.new`'s bare `Nominal[Array]` (no type args) IS a carrier and is
      # absorbed, so #615's seed keeps closing rather than growing a second arm.
      #
      # **`nil` is the one member the mutation itself refutes, and it does not survive.** The rule
      # above is a rule about ABSENCE of evidence — the seam cannot say a `Dynamic` or a foreign
      # `Nominal` was mutated as an Array, so it must not rewrite it. `NilClass` defines no content
      # mutator at all, so on every path where the body ran the binding was not nil; only the
      # zero-iteration path keeps the arm, and that path is modelled upstream (the `while` base
      # scope's nil-injection, slice A's `Constant[nil]` fixpoint seed) rather than here. Keeping it
      # measured out as a pure cost: `r = nil; while …; r ||= []; r << x; end; r.each` gained a
      # `call.possible-nil-receiver` on an idiom Rubyists write deliberately, while the genuinely
      # live nil arm is already reported once — at the mutation site, where `r << x` draws the same
      # diagnostic. This is the only member the join can refute without a method lookup it has no
      # environment for; the general "the mutator is undefined on this member" rule would buy
      # rarer shapes for machinery this seam does not have.
      NON_SURVIVING_CLASSES = %w[NilClass].freeze

      # Pre-state members the rederived Array does not stand for: a whole-variable `Dynamic`, a
      # non-nil `Constant`, a foreign `Nominal`, a `Refined`. Mirrors {#collection_element_types}'s
      # recursion so the absorbed set and the residue partition the union exactly. A `Difference` is
      # absorbed with its base (`non-empty-array[T]` is an Array carrier) and otherwise kept whole,
      # refinement and all.
      def array_residue(type)
        case type
        when Type::Union then type.members.flat_map { |m| array_residue(m) }
        when Type::Tuple then []
        when Type::Nominal then type.class_name == "Array" ? [] : keep_member(type)
        when Type::Difference then array_residue(type.base).empty? ? [] : [type]
        else keep_member(type)
        end
      end

      # The Hash-side twin of {#array_residue}, mirroring {#hash_shape_key_values}. A bare
      # `Nominal[Hash]` with no type args is a carrier here even though it yields no key/value
      # evidence — `Hash.new` must close like `Array.new`, not grow an arm.
      def hash_residue(type)
        case type
        when Type::Union then type.members.flat_map { |m| hash_residue(m) }
        when Type::HashShape then []
        when Type::Nominal then type.class_name == "Hash" ? [] : keep_member(type)
        when Type::Difference then hash_residue(type.base).empty? ? [] : [type]
        else keep_member(type)
        end
      end

      # `[type]`, unless the mutation refutes the member outright — see {NON_SURVIVING_CLASSES}.
      def keep_member(type)
        NON_SURVIVING_CLASSES.include?(evidence_class(type)) ? [] : [type]
      end

      def with_residue(carrier, residue)
        residue.empty? ? carrier : Type::Combinator.union(*residue, carrier)
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

      # Element types carried by a collection binding, regardless of which carrier holds them: a
      # `Tuple` lists them, a `Nominal[Array, [E]]` has one element param, a bare `Array` /
      # anything else yields none.
      #
      # A `Difference` reads through to its base: `non-empty-array[T]` holds `T`s, and the seams
      # that read a seed from BEFORE the arity-forget ran (see {#join_array_content}) meet the
      # refinement carrier itself where they used to meet the base the widening had left. Declining
      # it there would hand the continuation the widened base ALONE, with every appended arm missing
      # — a wrong type, not a wide one.
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
        when Type::Difference
          collection_element_types(type.base)
        else
          []
        end
      end

      # `[keys, values]` evidence from a Hash-ish pre-state binding — a `HashShape` (literal pairs)
      # or a `Nominal[Hash, [K, V]]`. A `Difference` (`non-empty-hash[K, V]`) reads through to its
      # base, as {#collection_element_types} does for the Array side.
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
        when Type::Difference
          hash_shape_key_values(type.base)
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
