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
      MUTATORS = %i[
        << concat insert prepend replace clear []= slice!
        sub! gsub! tr! tr_s! delete! squeeze! succ! next!
        upcase! downcase! capitalize! swapcase! reverse!
        strip! lstrip! rstrip! chomp! chop! force_encoding
      ].to_set.freeze

      # The {MUTATORS} that can leave the receiver EMPTY, and so retract a `non-empty-string` refinement. The
      # rest are appenders or same-length rewrites: `s << x` / `s.prepend(x)` / `s.upcase!` cannot empty a
      # string that already holds a character, so the refinement is still provable afterwards.
      EMPTYING_MUTATORS = %i[
        replace clear slice! []=
        sub! gsub! delete! squeeze! strip! lstrip! rstrip! chomp! chop!
      ].to_set.freeze

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
    end
  end
end
