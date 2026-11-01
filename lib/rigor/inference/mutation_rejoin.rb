# frozen_string_literal: true

require_relative "../type"
require_relative "content_join"
require_relative "rewrite_mutation"

module Rigor
  module Inference
    # The re-join half of the mutation widening (issue #580): what happens to the SECOND and later
    # content mutations of one collection, once {MutationWidening} has already replaced the literal
    # carrier with a `Nominal`.
    #
    # Split out of {MutationWidening} because it answers a different question. That module decides
    # what a mutation FALSIFIES about a literal shape; this one decides when a carrier is still open
    # enough to LEARN from, which is a provenance question the type system has no field for and this
    # file answers off the carrier itself.
    module MutationRejoin
      module_function

      # Re-opens a carrier this seam already widened once, so the SECOND and later stores into the
      # same collection are seen (issue #580).
      #
      # Before this arm the widening was a one-way door: the first content mutation replaced the
      # literal `Tuple` / `HashShape` with a `Nominal`, `widen_for_mutator` had no `Nominal` arm, and
      # `a = []; a.push(1); a.push("s")` closed at `Array[Integer | Dynamic[top]]` with the `String`
      # arm simply absent. The `Dynamic` arm kept that from being a WRONG answer — nothing folds and
      # nothing dispatches off a union carrying it — but the carrier still did not say what the
      # program holds, and every precision lever that would eventually take the gradual arm off had
      # to inherit the missing store.
      #
      # `nil` when the re-join changed nothing, so a non-adder (`pop`, `sort!`) on an already-widened
      # carrier does not rebind the binding at all: a rebind drops the per-slot narrowings `with_local`
      # keys to the old value, and paying that for an identical type is a straight loss.
      def widen_nominal(nominal, method_name, values: :widen, arg_types: MutationWidening::NO_ARG_TYPES,
                        synthesised: false)
        if synthesised && synthesised_carrier?(nominal)
          return widen_synthesised(nominal, method_name, values:, arg_types:)
        end
        return widen_precise_array(nominal, method_name, values:, arg_types:) if precise_array?(nominal)
        return nil unless regrowable_carrier?(nominal)

        pre_state = values == :widen ? value_pin_widened_args(nominal) : nominal
        rejoined =
          case nominal.class_name
          when "Array"
            return nil unless MutationWidening::ARRAY_MUTATORS.include?(method_name)

            MutationWidening.join_added_elements(pre_state, method_name, arg_types,
                                                 pinned_evidence(ContentJoin.collection_element_types(pre_state)))
          when "Hash"
            return nil unless MutationWidening::HASH_MUTATORS.include?(method_name)

            seed_keys, seed_values = ContentJoin.hash_shape_key_values(pre_state)
            MutationWidening.join_added_pairs(pre_state, method_name, arg_types,
                                              [pinned_evidence(seed_keys), pinned_evidence(seed_values)])
          end
        # The arm lands after the precise parameters are restored: a rewriter falsifies a proven side too
        # (`Hash.new(0)` under `transform_values!(&:to_s)` holds Strings), which an adder's one store cannot.
        rejoined = RewriteMutation.arm(keep_precise_parameters(pre_state, rejoined), method_name)
        rejoined == nominal ? nil : rejoined
      end

      # Re-grows only the parameters that were already gradual, restoring every other one.
      #
      # {#regrowable_carrier?} asks the carrier as a whole, but a `Hash` has two parameters and they
      # can disagree: `Hash.new(0)` is `Hash[Dynamic[top], Integer]` — an open key side over a value
      # side the default-arg fold PROVED. Re-joining both put the gradual floor on the value side and
      # cost the counter idiom (`h = Hash.new(0); h[:x] += 1; h[:x]`) its `Integer` for a
      # `Dynamic[top] | Integer`, a precision loss for evidence the key side alone was missing.
      #
      # The restored side comes from the pin-widened pre-state rather than the original carrier, so a
      # slot-rewriting mutator still falsifies the pinning it falsifies.
      def keep_precise_parameters(pre_state, rejoined)
        return rejoined unless rejoined.is_a?(Type::Nominal) && rejoined.type_args.size == pre_state.type_args.size

        args = pre_state.type_args.each_with_index.map do |arg, i|
          gradual_parameter?(arg) ? rejoined.type_args[i] : arg
        end
        Type::Combinator.nominal_of(rejoined.class_name, type_args: args)
      end

      # The class claim a re-opened carrier still makes, for {ContentJoin.admissible_evidence} to gate
      # the added members against.
      #
      # It is the carrier's VALUE-PINNED arms and nothing else, because pinning is the only trace a
      # literal seed's own elements leave once the carrier is nominal. Reading the whole element list
      # instead gets both ends wrong. {ContentJoin.admissible_evidence} answers "everything is
      # admissible" for a seed carrying a `Dynamic`, and a re-opened carrier ALWAYS carries one — its
      # own gradual floor — so the gate would be off exactly where it is needed: haml's
      # `temple = [:multi]` grew an `Array[…]` arm past its hand-written `-> Array[:multi]` and brought
      # the #561 `def.return-type-mismatch` back. Gating on the full list is the opposite error — after
      # `a = []; a.push(1)` the carrier reads `Array[Integer | Dynamic[top]]`, and a class set of
      # `{Integer}` floors the `"s"` the next line stores, which is the whole answer this issue is
      # about. The pinning tells the two apart: `:multi` is a claim the author's literal made, `Integer`
      # is this seam's own join talking back to itself.
      #
      # No pinned arm means no claim to contradict — an empty-seeded accumulator — and the added
      # evidence is admitted as itself.
      def pinned_evidence(members)
        members.flat_map { |m| ContentJoin.union_members(m) }.grep(Type::Constant)
      end

      # Which nominals may re-grow — the FP boundary this whole issue turns on, read off the carrier
      # itself rather than out of a side table.
      #
      # A carrier that already carries a gradual arm on the parameter the mutation feeds is one this
      # seam (or a declaration) has already declared open. Growing it is free of the #561 blast
      # radius by construction: adding a member to a union that already contains `Dynamic[top]`
      # cannot make the union reject a declared type it accepted, cannot manufacture a constant fold
      # (a union carrying `Dynamic` never folds), and cannot make a dispatch that was quiet fire.
      # What it CAN do is stop dropping evidence — which is the whole point.
      #
      # A PRECISE nominal is refused, and that is exactly the case the issue names: haml's
      # hand-written `-> Array[:multi]`, or an `Array[Symbol]` an RBS signature declares. Its element
      # set is a claim somebody made about the collection, not a residue of this seam's own
      # one-store guesswork, and joining a foreign member into it is what drew eight
      # `def.return-type-mismatch` on correct code (PR #561). The seed-admissibility gate in
      # {ContentJoin.admissible_evidence} stays the guard for everything that does get through.
      #
      # This is a superset of "mutation-widened": a DECLARED `Array[untyped]` or
      # `Array[Integer | untyped]` matches too. Deliberate — the soundness argument above is about
      # the carrier being open, not about who opened it, and a declared gradual arm is the author
      # saying the collection may hold anything.
      #
      # Issue #2555 L3 — the provenance this boundary turns on travels beside the binding, not with the value: a
      # local whose object the engine built carries the `:synthesised` construction fact ({Scope#construction_fact?}),
      # and {#widen_synthesised} answers for it before this predicate is asked. A field on `Type::Nominal` was the
      # other route; `Combinator.union`'s structural dedupe would keep whichever tagged twin it met first.
      def regrowable_carrier?(nominal)
        return false unless %w[Array Hash].include?(nominal.class_name)

        nominal.type_args.any? { |arg| gradual_parameter?(arg) }
      end

      # Issue #2555 L3 — a PRECISE `Array` / `Hash` nominal (no parameter carries a `Dynamic` arm), the carrier
      # {#widen_synthesised} re-grows when its binding carries the `:synthesised` fact. A carrier that already carries
      # a gradual arm keeps the ordinary re-join, whose floor it holds already.
      def synthesised_carrier?(nominal)
        %w[Array Hash].include?(nominal.class_name) && !nominal.type_args.empty? &&
          nominal.type_args.none? { |arg| gradual_parameter?(arg) }
      end

      # Issue #2555 L3 — the re-join for a precise carrier the engine built itself: a collection literal closed by a
      # value-preserving mutator (`a = [1, 2]; a.sort!` is `Array[1 | 2]`, `g = { a: 1 }; g.delete(:b)` is
      # `Hash[Symbol, 1]`), a constructor fold (`Array.new(n, 0)` is `Array[Integer]`), or a literal built as a
      # nominal outright (`{ ENV["A"].to_s => 1 }`). Its element types are this engine's inference, not a claim a
      # declaration made, so the #561 boundary ({#regrowable_carrier?}, {#precise_admitted}) does not apply:
      #
      # - an added member joins as itself (value pin and literal shape dropped, {MutationWidening.value_pin_widened}),
      #   with no seed-admissibility gate and no `Dynamic[top]` floor — `Array.new(n, 0) << "s"` reads
      #   `Array[Integer | String]`;
      # - a rewriter takes {RewriteMutation.arm}'s gradual position, as a gradual carrier does —
      #   `g.transform_values!(&:to_s)` reads `Hash[Symbol, Dynamic[top]]`;
      # - an adder whose arguments yield no evidence is one unknown store and joins `Dynamic[top]`; one called with no
      #   argument types at all (the block-capture seam, whose content join adds the stores afterwards) changes
      #   nothing.
      #
      # The floor the ordinary re-join adds exists because a carrier it closed could not re-grow; this one stays
      # re-growable for as long as the binding keeps the fact, so every later store is seen. What it does not see is
      # a remover taking a store out again: `a << 1; a.pop` leaves the `Integer` arm, the carrier's honest "may
      # hold" summary.
      def widen_synthesised(nominal, method_name, values:, arg_types:)
        pre_state = values == :widen ? value_pin_widened_args(nominal) : nominal
        rejoined =
          case nominal.class_name
          when "Array"
            return nil unless MutationWidening::ARRAY_MUTATORS.include?(method_name)

            synthesised_array_join(RewriteMutation.arm(pre_state, method_name), method_name, arg_types)
          when "Hash"
            return nil unless MutationWidening::HASH_MUTATORS.include?(method_name)

            synthesised_hash_join(RewriteMutation.arm(pre_state, method_name), method_name, arg_types)
          end
        rejoined == nominal ? nil : rejoined
      end

      def synthesised_array_join(carrier, method_name, arg_types)
        return carrier unless ContentJoin::ARRAY_CONTENT_ADDERS.include?(method_name) && !arg_types.empty?

        added = MutationWidening.value_pin_widened(ContentJoin.array_added_elements(method_name, arg_types))
        ContentJoin.join_array_content(carrier, added.empty? ? [Type::Combinator.untyped] : added)
      end

      def synthesised_hash_join(carrier, method_name, arg_types)
        return carrier unless ContentJoin::HASH_CONTENT_ADDERS.include?(method_name) && !arg_types.empty?

        # A `nil` key marks a splat, an unknown key ({MutationWidening.join_added_pairs}).
        key, value = MutationWidening.value_pin_widened([arg_types.first || Type::Combinator.untyped, arg_types.last])
        value ||= Type::Combinator.untyped
        ContentJoin.join_hash_content(carrier, [[key, value]])
      end

      def gradual_parameter?(type)
        ContentJoin.union_members(type).any?(Type::Dynamic)
      end

      # A typed `Array[E]` whose `E` has no `Dynamic` arm — the carrier {#regrowable_carrier?} refuses.
      def precise_array?(nominal)
        nominal.class_name == "Array" && nominal.type_args.size == 1 && !gradual_parameter?(nominal.type_args.first)
      end

      # Issue #2361 — a PRECISE `Array[E]` re-grows under a store, on the literal arms' terms: `a = ARGV.dup;
      # a.clear; a << 1; a.each { |v| v.fdiv(2) }` read `Array[String]` and reported `undefined method 'fdiv' for
      # String` on code that prints `[0.5]`.
      #
      # Only a content adder ({ContentJoin::ARRAY_CONTENT_ADDERS}) re-grows it, and the join keeps the seed: `clear`
      # empties the array but leaves `E` standing, a superset of what it holds. A remover leaves the carrier as it
      # found it. An element rewriter (`map!`, `collect!`, `flatten!`) replaces `E` (issue #2427): with the element
      # the non-bang counterpart answers when the call site could type it ({RewriteMutation.typed}, answered before
      # this method), and otherwise with {RewriteMutation.arm}'s gradual element — `a.map!.with_index { … }` holds
      # whatever the block returns, and keeping the stale `E` reported a missing method on correct code.
      #
      # Each added member the element accepts joins as itself; any other takes the `Dynamic[top]` floor
      # ({#precise_admitted}), and the floor joins every re-grow as it does on the literal arms. `a << 1` therefore
      # reads `Array[Dynamic[top] | String]` and `s = ints.map { "x" }; s << "y"` reads `Array["x" | Dynamic[top]]`.
      # Nothing narrows a carrier back when a remover or rewriter takes the store out again (`a << 1; a.pop`,
      # `a << nil; a.compact!`, `a.map!(&:to_s)`), so a joined `Integer` or `nil` made `t.take(a)` against a declared
      # `Array[String]` report `call.argument-type-mismatch`, and a parameter returned as its declared
      # `-> Array[String]` report `def.return-type-mismatch`, on correct Ruby. A union carrying the floor neither folds
      # nor dispatches loudly, so the read stays silent. Once floored, the carrier is gradual and later stores re-join
      # through {#widen_nominal}'s ordinary arm.
      #
      # A store the element already accepts changes nothing ({#already_held?}). An adder with no argument types at
      # all is left alone, as {MutationWidening.join_added_elements} leaves it: the block-capture seams pass none,
      # and their own content join adds the stores.
      def widen_precise_array(nominal, method_name, values:, arg_types:)
        return RewriteMutation.arm(nominal, method_name) if RewriteMutation::TYPED_COUNTERPARTS.key?(method_name)
        return nil unless ContentJoin::ARRAY_CONTENT_ADDERS.include?(method_name) && !arg_types.empty?

        stored = ContentJoin.array_added_elements(method_name, arg_types)
        return nil if already_held?(nominal.type_args.first, stored)

        added = MutationWidening.value_pin_widened(stored)
        admitted = precise_admitted(nominal.type_args.first, added)
        pre_state = values == :widen ? value_pin_widened_args(nominal) : nominal
        rejoined = ContentJoin.join_array_content(pre_state, MutationWidening.gradual_floor(admitted))
        rejoined == nominal ? nil : rejoined
      end

      # The seed-admissibility gate for a precise element: an added member joins as itself only when `element`
      # already accepts it, and takes the `Dynamic[top]` floor otherwise. A precise element therefore never gains a
      # member it rejects, which is what a declared boundary checks: nothing narrows the carrier back when a remover
      # or rewriter takes the store out again, and a joined foreign arm stays rejected beside the floor — `Integer`
      # under a declared `Array[String]`, `String` under `-> Array["x"]`, `Array[Integer]` under
      # `Array[Array[String]]` each reported on correct Ruby. A class set ({ContentJoin.admissible_evidence}) is too
      # coarse for that: it admits `Array[Integer]` beside `[String]` and `"y"` beside `"x"`.
      def precise_admitted(element, added)
        added.flat_map do |type|
          ContentJoin.union_members(type).map do |member|
            Acceptance.accepts(element, member).yes? ? member : Type::Combinator.untyped
          end
        end
      end

      # True when the precise element `element` already covers every type `stored` puts in, so the store changes
      # nothing: `s = ints.map { "x" }; s << "x"` keeps `Array["x"]` and its `s.last == "x"` fold, which is correct,
      # and a `[Integer, Integer]` pushed onto an `Array[[0 | Integer, Integer]]` keeps the Tuple element. Joining
      # the value-pin-widened, shape-erased store instead would only lose precision.
      #
      # A stored type carrying `Dynamic` anywhere is never covered, though `Acceptance` passes it gradually: keeping
      # the element would claim the unknown part is what the element says (`retry_binding_accepted?`'s rule).
      def already_held?(element, stored)
        return false if stored.empty?

        held = ContentJoin.union_members(element)
        stored.all? do |type|
          next false if type.nil? || carries_dynamic?(type)

          ContentJoin.union_members(type).all? { |member| held.include?(member) } ||
            Acceptance.accepts(element, type).yes?
        end
      end

      def carries_dynamic?(type)
        case type
        when Type::Dynamic then true
        when Type::Union, Type::Intersection then type.members.any? { |member| carries_dynamic?(member) }
        when Type::Nominal then type.type_args.any? { |arg| carries_dynamic?(arg) }
        when Type::Tuple then type.elements.any? { |element| carries_dynamic?(element) }
        when Type::HashShape then type.pairs.each_value.any? { |value| carries_dynamic?(value) }
        when Type::Difference, Type::Refined then carries_dynamic?(type.base)
        else false
        end
      end

      # The value-rewriting counterpart of {MutationWidening.widen_tuple}'s `values: :widen`. A mutator that lands a
      # new value in an EXISTING slot falsifies that slot's pinning on a re-opened carrier exactly as
      # it does on a literal one, so `d = [:multi]; d << x; d[0] = "s"` must not keep reading `:multi`
      # back out of slot 0.
      def value_pin_widened_args(nominal)
        Type::Combinator.nominal_of(nominal.class_name,
                                    type_args: nominal.type_args.map { |a| Type::Combinator.widen_value_pinned(a) })
      end

      # Rebinds `name` to the widened carrier, carrying across what a re-join must not lose.
      def rebind(scope, builder, name, widened, pre_state:, kind:)
        rebound = scope.public_send(builder, name, widened)
        pre_state.is_a?(Type::Nominal) ? carry_slot_narrowings(rebound, scope, kind, name) : rebound
      end

      # Re-installs the per-slot `receiver[key] ||= default` narrowings that rebinding the receiver
      # drops.
      #
      # `Scope#with_local` drops them because a rebind normally means a DIFFERENT object, and the
      # slot's non-nil guarantee was about the old one. A re-join (issue #580) is the opposite: the
      # binding still names the same object, and only the summary of what it holds grew. Before the
      # `Nominal` arm existed the second store into an already-widened carrier rebound nothing at
      # all, so the narrowing survived by accident — Redmine's `params[:f] ||= []` then
      # `params[:op] ||= {}` idiom lost `:f`'s narrowing the moment `:op` re-joined, and the next
      # `params[:f] << :status` dispatched on nil again. Carrying them keeps the re-join's scope
      # effect to the one thing it actually learned.
      #
      # The call recording its OWN key runs after the widening (`eval_index_or_write` orders it that
      # way deliberately), so a carried entry never shadows a fresher one for the same slot.
      # Method-chain narrowings are deliberately NOT carried: `x.last` is a claim about a position a
      # content mutation really can move.
      def carry_slot_narrowings(rebound, pre_scope, kind, name)
        pre_scope.indexed_narrowings.reduce(rebound) do |acc, (key, type)|
          next acc unless key.receiver_kind == kind && key.receiver_name == name.to_sym

          acc.with_indexed_narrowing(key.receiver_kind, key.receiver_name, key.key, type)
        end
      end
    end
  end
end
