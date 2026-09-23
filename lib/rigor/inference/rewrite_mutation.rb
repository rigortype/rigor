# frozen_string_literal: true

require_relative "../type"
require_relative "refinement_mutation"

module Rigor
  module Inference
    # The in-place mutators whose ARGUMENTS do not describe what they store — the other half of what
    # {MutationWidening} joins. A block computes the value (`map!`, `transform_values!`, a block-form `fill`), the
    # argument is a collection whose contents {ContentJoin} does not read for that name (`merge!`, `Hash#replace`),
    # or the stored values are the receiver's own elements taken apart (`flatten!`).
    #
    # The widening kept the SEED's types for such a site, because nothing it joins describes the new values:
    # `a = [1]; a.map!(&:to_s)` read `Array[Integer]`, and `a.first.upcase` drew a false
    # `undefined method 'upcase' for Integer`. The seam cannot see the values, so the answer at each position the
    # mutator writes is gradual — {REPLACED} or {JOINED}, depending on whether the old values can survive it.
    module RewriteMutation
      # Mutators that rewrite EVERY value at the listed type-argument positions, keyed by carrier class: nothing the
      # seed held there is known to survive, so the position becomes `Dynamic[top]` outright. Keeping the seed beside
      # the gradual arm would leave a closed claim about values that are gone — `a = [1, 2]; a.map!(&:to_s)` read
      # `Array[1 | 2 | Dynamic[top]]`, which a hand-written `-> Array[String]` rejects on correct code, and the kept
      # `1` gated a later `a << "x"` out of the re-join as foreign evidence. `Array#replace` is listed although its
      # argument IS its new content: {MutationWidening#join_added_elements} still joins that evidence after the
      # replacement, and the seed it would otherwise keep beside it is gone.
      REPLACED = {
        "Array" => { map!: [0], collect!: [0], flatten!: [0], replace: [0] }.freeze,
        "Hash" => { transform_keys!: [0], transform_values!: [1], replace: [0, 1] }.freeze
      }.freeze

      # Mutators that store values nothing describes BESIDE values they may keep: `fill(x, start)` leaves the slots
      # before `start`, and `merge!` / `update` leave every key the argument lacks. The listed positions join
      # `Dynamic[top]` and keep the seed's own arms.
      #
      # `fill` is listed although its no-block form's argument IS its value: the widening cannot see the block, and
      # the arm costs the argument form nothing, since {MutationWidening#join_added_elements} already floors every
      # straight-line store it joins. `merge!` on a `Hash.new(0)` counter opens the value side the default proved
      # (`Dynamic[top] | Integer`), since the seam cannot tell a merging block or a foreign argument from neither.
      JOINED = {
        "Array" => { fill: [0] }.freeze,
        "Hash" => { merge!: [0, 1], update: [0, 1] }.freeze
      }.freeze

      module_function

      # True when `method_name` is a rewriter for some carrier class.
      def rewriter?(method_name)
        [REPLACED, JOINED].any? { |table| table.each_value.any? { |names| names.key?(method_name) } }
      end

      # `carrier` with each position `method_name` rewrites made gradual — replaced for a {REPLACED} name, joined
      # for a {JOINED} one; any carrier other than an `Array` / `Hash` nominal, or a name neither table lists for its
      # class, is returned untouched. Idempotent, so a path that reaches it twice answers the same.
      def arm(carrier, method_name)
        return carrier unless carrier.is_a?(Type::Nominal) && !carrier.type_args.empty?

        replaced = REPLACED.dig(carrier.class_name, method_name) || []
        joined = JOINED.dig(carrier.class_name, method_name) || []
        return carrier if replaced.empty? && joined.empty?

        args = carrier.type_args.each_with_index.map do |arg, i|
          if replaced.include?(i) then Type::Combinator.untyped
          elsif joined.include?(i) then Type::Combinator.union(arg, Type::Combinator.untyped)
          else arg
          end
        end
        Type::Combinator.nominal_of(carrier.class_name, type_args: args)
      end

      # {.arm} through a `Union` (member by member) and an empty-witness refinement (its base, keeping the witness
      # only when the mutator cannot empty the receiver — {RefinementMutation.preserves_witness?}). For a carrier
      # the ADR-56 slice-C join rebuilt from its seed, which knows the adders' content but not the rewrite.
      def arm_through(type, method_name)
        case type
        when Type::Union then Type::Combinator.union(*type.members.map { |member| arm_through(member, method_name) })
        when Type::Difference then arm_refinement(type, method_name)
        else arm(type, method_name)
        end
      end

      def arm_refinement(difference, method_name)
        base = difference.base
        return difference unless difference.removes_empty_witness? && base.is_a?(Type::Nominal)

        armed = arm(base, method_name)
        return difference if armed.equal?(base)

        kept = RefinementMutation.preserves_witness?(base.class_name, method_name)
        kept ? Type::Combinator.difference(armed, difference.removed) : armed
      end

      # `values`, or `:keep` when `method_name` rewrites the carrier's value position (an `Array`'s element, a
      # `Hash`'s value) — the pre-state widening's pinning mode.
      #
      # Erasing the pinning there buys nothing and costs the #561 guarantee. The erasure exists to stop a stale
      # constant fold (issue #560), and a union carrying `Dynamic` never folds; but the erased form is a CLOSED
      # class a {JOINED} arm then sits beside, and one a hand-written signature pinning the seed rejects — haml's
      # `-> Array[:multi]` accepts `Array[:multi | Dynamic[top]]`, not `Array[Dynamic[top] | Symbol]`. A {REPLACED}
      # position discards the pinning either way.
      #
      # `type` is the widening's pre-state; a `Union` answers `values` and each member asks again as it widens.
      def values_mode(type, method_name, values)
        class_name = value_carrier_class(type)
        return values if class_name.nil?

        value_position = class_name == "Hash" ? 1 : 0
        rewritten = [REPLACED, JOINED].any? { |table| table.dig(class_name, method_name)&.include?(value_position) }
        rewritten ? :keep : values
      end

      def value_carrier_class(type)
        case type
        when Type::Tuple then "Array"
        when Type::HashShape then "Hash"
        when Type::Nominal then type.class_name
        end
      end
      private_class_method :value_carrier_class, :arm_refinement
    end
  end
end
