# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    class ExpressionTyper
      # The per-element assemblers `Array#map` / `select` / `reject` / `partition` / `find` / … reach when a block is
      # folded once per Tuple position: pure functions from the per-position block results and the receiver's element
      # types to the call's type, or nil to decline. Reads no state and calls back nothing. The entry is
      # `assemble_per_element_result`; the dispatch table moved with it. `NO_MATCH` stays in {ExpressionTyper}, read
      # lexically.
      module PerElementAssemblers
        module_function

        PER_ELEMENT_ASSEMBLERS = {
          map: :assemble_map_result,
          collect: :assemble_map_result,
          filter_map: :assemble_filter_map_result,
          flat_map: :assemble_flat_map_result,
          collect_concat: :assemble_flat_map_result,
          select: :assemble_select_result,
          filter: :assemble_select_result,
          find_all: :assemble_select_result,
          reject: :assemble_reject_result,
          take_while: :assemble_take_while_result,
          drop_while: :assemble_drop_while_result,
          partition: :assemble_partition_result,
          count: :assemble_count_result,
          find: :assemble_find_result,
          detect: :assemble_find_result,
          rfind: :assemble_rfind_result,
          find_index: :assemble_find_index_result,
          index: :assemble_find_index_result,
          rindex: :assemble_rindex_result
        }.freeze
        private_constant :PER_ELEMENT_ASSEMBLERS

        def assemble_per_element_result(method_name, per_position, element_types)
          handler = PER_ELEMENT_ASSEMBLERS[method_name]
          send(handler, per_position, element_types) if handler
        end

        def assemble_map_result(per_position, _element_types)
          Type::Combinator.tuple_of(*per_position)
        end

        def assemble_select_result(per_position, element_types)
          assemble_filter_result(per_position, element_types, keep_on_truthy: true)
        end

        def assemble_reject_result(per_position, element_types)
          assemble_filter_result(per_position, element_types, keep_on_truthy: false)
        end

        # `select` / `filter` / `reject`: keeps each receiver element whose per-position predicate result
        # folds to a decisive `Constant` — Ruby-truthy for `select` / `filter`, Ruby-falsey for `reject`. The
        # surviving elements assemble into a `Tuple`, strictly tighter than the RBS-projected `Array[Elem]`.
        #
        # Folds tightly only when EVERY position is a `Constant`: a single non-`Constant` position leaves the
        # result cardinality unknown (the element might or might not survive), so this assembler declines and
        # {ExpressionTyper#undecided_fold_floor} answers `Array[Elem]`. `[].select` style empty results are sound — an
        # empty `Tuple` is the empty-array carrier.
        def assemble_filter_result(per_position, element_types, keep_on_truthy:)
          return nil unless per_position.all?(Type::Constant)

          kept = element_types.each_index.filter_map do |index|
            element_types[index] if truthy_constant?(per_position[index]) == keep_on_truthy
          end
          Type::Combinator.tuple_of(*kept)
        end

        # `take_while` / `drop_while`: stops at the first falsey `Constant` position when every preceding
        # position is a truthy `Constant` (or takes/drops all elements when every position is a truthy
        # `Constant`). Declines when an undecided position precedes the stopping point.
        def assemble_take_while_result(per_position, element_types)
          cutoff = leading_truthy_cutoff(per_position)
          return nil if cutoff.nil?

          Type::Combinator.tuple_of(*element_types[0...cutoff])
        end

        def assemble_drop_while_result(per_position, element_types)
          cutoff = leading_truthy_cutoff(per_position)
          return nil if cutoff.nil?

          Type::Combinator.tuple_of(*element_types[cutoff..])
        end

        def leading_truthy_cutoff(per_position)
          first_falsey_index = per_position.index { |type| falsey_constant?(type) }
          return (per_position.all?(Type::Constant) ? per_position.size : nil) if first_falsey_index.nil?
          return nil unless per_position[0...first_falsey_index].all?(Type::Constant)

          first_falsey_index
        end

        # `partition`: returns `Tuple[truthy_tuple, falsey_tuple]` when every position folds to a `Constant`.
        def assemble_partition_result(per_position, element_types)
          return nil unless per_position.all?(Type::Constant)

          truthy = assemble_filter_result(per_position, element_types, keep_on_truthy: true)
          falsey = assemble_filter_result(per_position, element_types, keep_on_truthy: false)
          Type::Combinator.tuple_of(truthy, falsey)
        end

        # `count`: returns `Constant[Integer]` of the truthy positions when every position folds to a `Constant`.
        def assemble_count_result(per_position, _element_types)
          return nil unless per_position.all?(Type::Constant)

          Type::Combinator.constant_of(per_position.count { |type| truthy_constant?(type) })
        end

        # `filter_map` folds tightly only when every per-position result is a `Constant`: positions whose
        # value is `nil` or `false` drop, the rest survive in declaration order. When any position is
        # non-Constant the dispatcher declines (returns nil) so the RBS tier widens to `Array[U]`.
        def assemble_filter_map_result(per_position, _element_types = nil)
          return nil unless per_position.all?(Type::Constant)

          kept = per_position.reject { |type| type.value.nil? || type.value == false }
          Type::Combinator.tuple_of(*kept)
        end

        # `flat_map` flattens a single level: if the per-position result is a `Tuple`, its elements are
        # concatenated; if it's a non-Array scalar carrier (`Constant<…>` over a non-Array literal) it
        # contributes one element. We fold tightly only when every per-position result is one of those two
        # recognisable shapes — `Nominal[Array[T]]`, `Union[…]`, and other opaque carriers decline so the RBS
        # tier widens to `Array[U]`.
        #
        # `Type::Constant` only ever holds non-Array scalars (the carrier rejects Array literals), so a single
        # `Constant` safely contributes itself as a single Tuple element.
        def assemble_flat_map_result(per_position, _element_types = nil)
          flattened = per_position.flat_map { |type| flat_map_contribution(type) }
          return nil if flattened.nil? || flattened.any?(&:nil?)

          Type::Combinator.tuple_of(*flattened)
        end

        def flat_map_contribution(type)
          case type
          when Type::Tuple then type.elements
          when Type::Constant then [type]
          else [nil]
          end
        end

        # `find` / `detect`: returns the first receiver element whose block result is Ruby-truthy, or `nil`
        # when no position folds to truthy.
        #
        # When the first decisive truthy position is found, the answer is the corresponding receiver element,
        # joined with the element of every earlier position whose result is not a `Type::Constant`: such a
        # position may match first, but the search ends at the truthy one whatever it answers, so the call
        # never returns `nil`. When every position folds to falsey, the answer is `Constant[nil]`. With no
        # decisive truthy position and some undecided one, it declines ({ExpressionTyper#undecided_fold_floor}).
        def assemble_find_result(per_position, element_types)
          candidates = first_match_candidates(per_position)
          return candidates if candidates.nil? || candidates.equal?(NO_MATCH)

          Type::Combinator.union(*candidates.map { |index| element_types[index] })
        end

        # `rfind`: reverse of `find` — returns the last receiver element whose block result is Ruby-truthy,
        # joined with any undecided positions to its right.
        def assemble_rfind_result(per_position, element_types)
          candidates = last_match_candidates(per_position)
          return candidates if candidates.nil? || candidates.equal?(NO_MATCH)

          Type::Combinator.union(*candidates.map { |index| element_types[index] })
        end

        # `find_index` / `index`: returns the index of the first truthy position, or `Constant[nil]` when
        # nothing matches, on {.assemble_find_result}'s terms.
        def assemble_find_index_result(per_position, _element_types = nil)
          candidates = first_match_candidates(per_position)
          return candidates if candidates.nil? || candidates.equal?(NO_MATCH)

          Type::Combinator.union(*candidates.map { |index| Type::Combinator.constant_of(index) })
        end

        # `rindex`: returns the index of the last truthy position, or `Constant[nil]` when nothing matches.
        def assemble_rindex_result(per_position, _element_types = nil)
          candidates = last_match_candidates(per_position)
          return candidates if candidates.nil? || candidates.equal?(NO_MATCH)

          Type::Combinator.union(*candidates.map { |index| Type::Combinator.constant_of(index) })
        end

        # The positions `find` may stop at — the first decisive truthy one and every undecided one before it —
        # `NO_MATCH` when every position folds falsey, or nil when an undecided position has no truthy one after it.
        def first_match_candidates(per_position)
          first_truthy_index = per_position.index { |type| truthy_constant?(type) }
          if first_truthy_index.nil?
            return per_position.all?(Type::Constant) ? NO_MATCH : nil
          end

          undecided = (0...first_truthy_index).reject { |index| per_position[index].is_a?(Type::Constant) }
          undecided + [first_truthy_index]
        end

        # The positions `rfind` / `rindex` may stop at — the last decisive truthy one and every undecided one
        # after it — `NO_MATCH` when every position folds falsey, or nil when an undecided position has no
        # truthy one before it.
        def last_match_candidates(per_position)
          last_truthy_index = per_position.rindex { |type| truthy_constant?(type) }
          if last_truthy_index.nil?
            return per_position.all?(Type::Constant) ? NO_MATCH : nil
          end

          undecided = ((last_truthy_index + 1)...per_position.size).reject do |index|
            per_position[index].is_a?(Type::Constant)
          end
          [last_truthy_index] + undecided
        end

        def truthy_constant?(type)
          type.is_a?(Type::Constant) && !type.value.nil? && type.value != false
        end

        def falsey_constant?(type)
          type.is_a?(Type::Constant) && (type.value.nil? || type.value == false)
        end

        private_class_method :assemble_map_result, :assemble_select_result, :assemble_reject_result,
                             :assemble_filter_result, :assemble_take_while_result, :assemble_drop_while_result,
                             :leading_truthy_cutoff, :assemble_partition_result, :assemble_count_result,
                             :assemble_filter_map_result, :assemble_flat_map_result, :flat_map_contribution,
                             :assemble_find_result, :assemble_rfind_result, :assemble_find_index_result,
                             :assemble_rindex_result, :first_match_candidates, :last_match_candidates,
                             :truthy_constant?, :falsey_constant?
      end
    end
  end
end
