# frozen_string_literal: true

require_relative "../type"
require_relative "block_call_timing"
require_relative "closure_escape_analyzer"

module Rigor
  module Inference
    # Whether a block-accepting call may run its block more than once, so a later run reads a captured binding an
    # earlier run moved. Two passes ask it and share this one rule: the block-return pass
    # (`ExpressionTyper#block_may_repeat?`), which lays the #587 (b) captured binding under such a block, and the
    # statement pass (`StatementEvaluator#repeating_block_entry`, issue #1412), which lays the ADR-56 WD2.13
    # content-mutation widening on its entry.
    #
    # The core iteration methods {ClosureEscapeAnalyzer} catalogues as non-escaping prove it — for a project class
    # too, through its ancestry (`include Enumerable`); `tap` / `then` / `yield_self` are catalogued there too but
    # run their block exactly once ({BlockCallTiming}).
    #
    # Issue #1234 — a receiver the analyzer cannot classify at all (`Dynamic`, a union, a project class whose
    # ancestry it cannot follow) repeats when the method NAME is a catalogued iterator the project does not define
    # on it ({ClosureEscapeAnalyzer.repeats_by_name?}): `items.all? { seen += 1; seen == 1 }` on an untyped `items`
    # kept the first run's `seen == 1`, the predicate folded to `true`, and the condition on the result was
    # reported as constant. This is a reading of `:unknown` for these two passes alone; escape analysis still
    # treats it as unproven. Any other name, and a receiver classified `:escaping`, answers false, which keeps the
    # entry scope: it is exact for a block run once (`m.synchronize { out = buf; buf = nil; out }` is `buf`'s value,
    # and a cross-iteration binding would add the `nil` a second run never reads).
    #
    # A receiver that provably holds at most one element runs the block at most once however it iterates, so it
    # answers false too: `done = false; [:only].each { break if done; done = true }` is `[:only]`, and the
    # cross-iteration `done` would have typed it `Array[Symbol]?`.
    module BlockRepetition
      module_function

      # `classification` is the receiver's {ClosureEscapeAnalyzer.classify} answer when the caller already holds it.
      def may_repeat?(method_name:, receiver_type:, scope:, classification: nil)
        return false if BlockCallTiming.candidate_name?(method_name)
        return false if at_most_one_run?(method_name, receiver_type)

        classification ||= ClosureEscapeAnalyzer.classify(
          receiver_type: receiver_type, method_name: method_name, scope: scope
        )
        case classification
        when :non_escaping then true
        when :unknown
          ClosureEscapeAnalyzer.repeats_by_name?(receiver_type: receiver_type, method_name: method_name, scope: scope)
        else false
        end
      end

      def at_most_one_run?(method_name, receiver_type)
        case receiver_type
        when Type::Tuple then receiver_type.elements.size <= 1
        when Type::HashShape then receiver_type.closed? && receiver_type.pairs.size <= 1
        when Type::Constant then constant_at_most_one_run?(method_name, receiver_type.value)
        else false
        end
      end

      # `1.times` and a one-element integer range iterate once.
      def constant_at_most_one_run?(method_name, value)
        case value
        when Integer then method_name == :times && value <= 1
        when Range
          value.begin.is_a?(Integer) && value.end.is_a?(Integer) &&
            value.end - value.begin + (value.exclude_end? ? 0 : 1) <= 1
        else false
        end
      end
    end
  end
end
