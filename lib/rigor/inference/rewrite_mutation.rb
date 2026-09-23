# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Inference
    # The in-place mutators whose ARGUMENTS do not describe what they store — the other half of what
    # {MutationWidening} joins. A block computes the value (`map!`, `transform_values!`, a block-form `fill`), the
    # argument is a collection whose contents {ContentJoin} does not read for that name (`merge!`, `Hash#replace`),
    # or the stored values are the receiver's own elements taken apart (`flatten!`).
    #
    # The widening kept the SEED's types for such a site, because nothing it joins describes the new values:
    # `a = [1]; a.map!(&:to_s)` read `Array[Integer]`, and `a.first.upcase` drew a false
    # `undefined method 'upcase' for Integer`. The answer here is the one-store answer
    # {MutationWidening.gradual_floor} gives an adder, for the same reason — the seam cannot see the values, so it
    # may not close the parameter.
    module RewriteMutation
      # The type-argument positions each mutator rewrites, keyed by carrier class. A position not listed keeps what
      # the widening left, so `transform_keys!` does not open the value side it cannot touch.
      #
      # `fill` is listed whole although its no-block form's argument IS its value: the widening cannot see the
      # block, and the arm costs the argument form nothing, since {MutationWidening#join_added_elements} already
      # floors every straight-line store it joins.
      POSITIONS = {
        "Array" => { map!: [0], collect!: [0], fill: [0], flatten!: [0] }.freeze,
        "Hash" => {
          transform_keys!: [0], transform_values!: [1], merge!: [0, 1], update: [0, 1], replace: [0, 1]
        }.freeze
      }.freeze

      module_function

      # `carrier` with `Dynamic[top]` joined into each position `method_name` rewrites; any carrier other than an
      # `Array` / `Hash` nominal, or a name {POSITIONS} does not list for its class, is returned untouched.
      #
      # The seed's arms stay beside the gradual one rather than being dropped: `Array[:multi | Dynamic[top]]` still
      # reads as accepted by haml's hand-written `-> Array[:multi]` (#561), and a union carrying `Dynamic` neither
      # folds nor dispatches loudly.
      def arm(carrier, method_name)
        return carrier unless carrier.is_a?(Type::Nominal)

        positions = POSITIONS.dig(carrier.class_name, method_name)
        return carrier if positions.nil? || carrier.type_args.empty?

        args = carrier.type_args.each_with_index.map do |arg, i|
          positions.include?(i) ? Type::Combinator.union(arg, Type::Combinator.untyped) : arg
        end
        Type::Combinator.nominal_of(carrier.class_name, type_args: args)
      end

      # `values`, or `:keep` when `method_name` puts {.arm}'s arm on the carrier's value position (an `Array`'s
      # element, a `Hash`'s value).
      #
      # Erasing the pinning there buys nothing and costs the #561 guarantee. The erasure exists to stop a stale
      # constant fold (issue #560), and a union carrying `Dynamic` never folds; but the erased form is a CLOSED
      # class the arm then sits beside, so `temple = [:multi]; temple.map!(&:itself)` read
      # `Array[Dynamic[top] | Symbol]`, which haml's hand-written `-> Array[:multi]` rejects. Kept, it reads
      # `Array[:multi | Dynamic[top]]` — the accepting form every other straight-line store leaves.
      #
      # `type` is the widening's pre-state; a `Union` answers `values` and each member asks again as it widens.
      def pinning(type, method_name, values)
        class_name = carrier_class(type)
        return values if class_name.nil?

        value_position = class_name == "Hash" ? 1 : 0
        POSITIONS.dig(class_name, method_name)&.include?(value_position) ? :keep : values
      end

      def carrier_class(type)
        case type
        when Type::Tuple then "Array"
        when Type::HashShape then "Hash"
        when Type::Nominal then type.class_name
        end
      end
    end
  end
end
