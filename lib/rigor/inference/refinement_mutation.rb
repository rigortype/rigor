# frozen_string_literal: true

require_relative "../type"
require_relative "string_mutation"

module Rigor
  module Inference
    # The empty-witness `Difference` arm of {MutationWidening} — `non-empty-array[T]`,
    # `non-empty-hash[K, V]` and `non-empty-string`, the refinement carriers `empty?` / `any?`
    # narrowing writes (ADR-47 §4-4).
    #
    # Two questions, which the seam used to answer as one. **What the receiver now holds** is the
    # ordinary content join, and it applies to a refinement exactly as it applies to a `Tuple`:
    # {MutationWidening} owns that algebra and passes it in. **Whether the receiver is still
    # provably non-empty** is this module's own, and it is a property of the mutator alone.
    #
    # Answering both with "widen to the bare base" was ADR-56 WD2.9's deferred branch (issue #936):
    # `if xs.any?; xs << "s"` read `Array[String]` for an array that holds a String too — a wrong
    # type, not a wide one — and lost a witness an append cannot falsify.
    module RefinementMutation
      # Mutators that CANNOT leave a non-empty receiver empty. Whitelists rather than a table of
      # emptiers: a name missing from these retracts the witness, which is the conservative answer
      # every mutator got before. The listed ones either only add (`<< push …`) or only permute a
      # fixed number of slots (`sort! map! …`); `replace`, `compact!`, `flatten!`, `uniq!` and every
      # remover are deliberately absent, since each has an input that empties the receiver.
      EMPTY_PRESERVING = {
        "Array" => %i[
          << push append prepend unshift concat insert
          map! collect! sort! sort_by! reverse! rotate! shuffle!
        ].to_set.freeze,
        "Hash" => %i[[]= store merge! update transform_keys! transform_values!].to_set.freeze
      }.freeze

      module_function

      # The widened binding for an empty-witness refinement about to be mutated by `method_name`,
      # or `nil` when nothing applies — including the case where the answer would be the pre-state
      # itself, which the seam's callers read as "no widening".
      #
      # The block receives the refinement's BASE and answers the base with the mutator's added
      # content joined in, or a falsey value to decline (the mutator is not in that base's table).
      # A String base is answered here instead: it carries no content parameter, so the only
      # question it has is the witness one.
      def widen(difference, method_name)
        return nil unless difference.removes_empty_witness?

        base = difference.base
        joined = base.class_name == "String" ? string_base(base, method_name) : yield(base)
        return nil unless joined

        widened = preserves_witness?(base.class_name, method_name) ? refine(joined, difference) : joined
        widened == difference ? nil : widened
      end

      # A `non-empty-string` survives every mutator that cannot empty the buffer, and those are
      # exactly the ones {StringMutation} does not list as emptying — so this arm declines them
      # and the refinement stands, rather than widening to `String` and dropping it.
      def string_base(base, method_name)
        StringMutation::EMPTYING_MUTATORS.include?(method_name) ? base : nil
      end

      def preserves_witness?(class_name, method_name)
        table = EMPTY_PRESERVING[class_name]
        !!table&.include?(method_name)
      end

      def refine(joined, difference)
        Type::Combinator.difference(joined, difference.removed)
      end
    end
  end
end
