# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Analysis
    module CheckRules
      # Issue #2296 — whether `def.return-type-mismatch` may report an inferred `Array[E]` against a declared tuple.
      #
      # An Array whose element `E` carries a `Dynamic` member is one an unknown store reached: the callee floor
      # (`UnknownStoreWidening.callee_block_floor`) widens `acc = [-7, 9]` to `Array[Dynamic[top] | Integer]` after a
      # `norm(acc)` that rewrites it in a block. A nominal Array never conforms to a tuple, so `accepts` answers `no`
      # against a declared `[Integer, Integer]`, yet nothing proves the tuple wrong: the length is unknown, and so are
      # the elements the gradual arm stands for. The rule therefore stays silent when, for some declared tuple, every
      # KNOWN member of `E` overlaps some element of that tuple. It still reports when a known member overlaps none
      # (`Array[Dynamic[top] | Integer]` against `[String, String]`), and when `E` has no `Dynamic` member at all.
      module GradualTupleReturn
        module_function

        # True when every member of `inferred` the declared return rejects is a gradual Array consistent with one of
        # `declared`'s tuples.
        def consistent?(declared, inferred)
          tuples = tuple_members(declared)
          return false if tuples.empty?

          members = inferred.is_a?(Type::Union) ? inferred.members : [inferred]
          members.all? do |member|
            !declared.accepts(member).no? || gradual_array_fits?(member, tuples)
          end
        end

        def gradual_array_fits?(type, tuples)
          return false unless type.is_a?(Type::Nominal) && type.class_name == "Array" && type.type_args.size == 1

          element = type.type_args.first
          parts = element.is_a?(Type::Union) ? element.members : [element]
          known, gradual = parts.partition { |part| !part.is_a?(Type::Dynamic) }
          return false if gradual.empty?

          tuples.any? do |tuple|
            known.all? { |part| tuple.elements.any? { |slot| overlaps?(slot, part) } }
          end
        end

        # Two types overlap when either accepts the other: `:html` and `Symbol`, `Integer` and `1`.
        def overlaps?(left, right)
          !left.accepts(right).no? || !right.accepts(left).no?
        end

        def tuple_members(declared)
          members = declared.is_a?(Type::Union) ? declared.members : [declared]
          members.grep(Type::Tuple)
        end
      end
    end
  end
end
