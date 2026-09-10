# frozen_string_literal: true

require_relative "../type"
require_relative "content_join"

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
      def widen_nominal(nominal, method_name, values: :widen, arg_types: MutationWidening::NO_ARG_TYPES)
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
        rejoined = keep_precise_parameters(pre_state, rejoined)
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
      # saying the collection may hold anything. Distinguishing the two needs provenance travelling
      # WITH the value (a field on `Type::Nominal`, reopening structural equality, `Marshal`, and the
      # cache schema); nothing on this axis needs it yet.
      def regrowable_carrier?(nominal)
        return false unless %w[Array Hash].include?(nominal.class_name)

        nominal.type_args.any? { |arg| gradual_parameter?(arg) }
      end

      def gradual_parameter?(type)
        ContentJoin.union_members(type).any?(Type::Dynamic)
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
