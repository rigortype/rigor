# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Inference
    # The String half of {MutationWidening}'s straight-line seam (issue #617 residue (4)).
    #
    # `s = +"ab"; s << "c"; s == "ab"` folded `flow.always-truthy-condition` on correct code: the seam
    # responded to `Tuple` / `HashShape` / empty-witness carriers only, while a `Constant[String]` is just as
    # falsified by an in-place mutator as a `Tuple` is by `<<`. The ADR-56 block-capture path already widened
    # the same binding, so the two seams disagreed about one carrier.
    #
    # It lives beside `MutationWidening` rather than inside it because the tables here answer a different
    # question from the Array / Hash ones: those partition a carrier's SHAPE evidence, this one partitions a
    # VALUE pin and an emptiness proof.
    module StringMutation
      # Receiver-mutating String methods only. The non-bang siblings (`upcase` vs `upcase!`, `sub` vs `sub!`)
      # return a new String and leave the receiver's value intact, so they stay precise.
      #
      # This is the one String table: `MutationWidening::SHAPE_MUTATORS` unions it with the Array and Hash ones, and
      # the effect classifier and the effect catalogue's `mutators: string` cite it rather than keep a list of their
      # own (ADR-103 WD3). A spec holds it to every bang method `String` defines plus the non-bang mutators reflection
      # cannot find by name.
      MUTATORS = %i[
        << concat insert prepend replace clear []= slice!
        setbyte bytesplice append_as_bytes force_encoding
        sub! gsub! tr! tr_s! delete! squeeze! succ! next!
        upcase! downcase! capitalize! swapcase! reverse!
        strip! lstrip! rstrip! chomp! chop!
        delete_prefix! delete_suffix! encode! scrub! unicode_normalize!
      ].to_set.freeze

      # The {MUTATORS} that CANNOT leave a non-empty receiver empty, and so keep a `non-empty-string` refinement:
      # appenders (`<<`, `concat`, `insert`, `prepend`, `append_as_bytes`), and rewrites that keep at least one
      # character (`setbyte`, `force_encoding`, the case mappings, `reverse!`, `succ!` / `next!`, `squeeze!`,
      # `unicode_normalize!`). A whitelist, as `RefinementMutation::EMPTY_PRESERVING` is for Array and Hash: a mutator
      # missing here retracts the witness, which costs precision, where a mutator missing from a list of emptiers kept
      # the witness of a string it had just emptied — `tr!` and `tr_s!` did, since `"a".tr!("a", "")` is `""`.
      EMPTY_PRESERVING = %i[
        << concat insert prepend append_as_bytes
        setbyte force_encoding
        upcase! downcase! capitalize! swapcase! reverse! succ! next! squeeze! unicode_normalize!
      ].to_set.freeze

      # `tr!` / `tr_s!` map every character they match to one character of the replacement (padded with its last), so
      # they empty the buffer only through an EMPTY replacement: `"a".tr!("a", "")` is `""`, `"a".tr!("a", "_")` is
      # `"_"`. They keep the witness when their second argument is provably a non-empty String.
      TRANSLATORS = %i[tr! tr_s!].to_set.freeze

      NO_ARG_TYPES = [].freeze

      module_function

      # `Constant["ab"]` under a String mutator → the bare `String` nominal. The pinned value is what the
      # mutation falsifies, and nothing else about the carrier survives it, so there is no `values: :keep`
      # half to preserve the way a `Tuple`'s surviving slots have one: an appended, substituted or
      # case-folded string is a different string.
      #
      # Only a String-valued `Constant` widens. Every other literal (`Integer`, `Symbol`, `Range`) can only
      # reach this arm through a name in the Array or Hash table and not in {MUTATORS}, and answering for it
      # would erase a value no in-place mutator on that class can change.
      #
      # `nil` — no widening — for every other input, which is the contract `MutationWidening#widen_for_mutator`
      # signals a decline with.
      def widen_constant(constant, method_name)
        return nil unless constant?(constant)
        return nil unless MUTATORS.include?(method_name)

        Type::Combinator.nominal_of("String")
      end

      def constant?(type)
        type.is_a?(Type::Constant) && type.value.is_a?(String)
      end

      # Whether `method_name`, called with `arg_types` (the call's positional argument types, possibly none), can leave
      # a non-empty receiver empty, and so retract a `non-empty-string` refinement. Every mutator outside
      # {EMPTY_PRESERVING} can, except a {TRANSLATORS} call whose replacement is provably non-empty.
      def may_empty?(method_name, arg_types = NO_ARG_TYPES)
        return false if EMPTY_PRESERVING.include?(method_name)
        return true unless TRANSLATORS.include?(method_name)

        !non_empty_string?(arg_types[1])
      end

      def non_empty_string?(type)
        case type
        when Type::Constant then constant?(type) && !type.value.empty?
        when Type::Difference then type.removes_empty_witness? && type.base.class_name == "String"
        when Type::Union then type.members.all? { |member| non_empty_string?(member) }
        else false
        end
      end
    end
  end
end
