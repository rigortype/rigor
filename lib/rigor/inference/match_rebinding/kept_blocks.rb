# frozen_string_literal: true

require "prism"

require_relative "../closure_escape_analyzer"
require_relative "../stored_block_call"

module Rigor
  module Inference
    module MatchRebinding
      # Whether a call may keep its block literal to run after it returns (issue #1364). A block a call keeps runs in
      # the frame that made it whenever a later call runs it — `on(:x) { |l| l =~ re }` hands a block that a later
      # `emit(:x, t)` runs — so a kept block that may match is a closure of that frame
      # ({MatchRebinding.matching_closure?}). The answer is by name, since the frame is scanned before most receivers
      # are bound: a project method named like a core iterator is read as one.
      module KeptBlocks
        # Calls that run their block only while they run: the core iterators of the closure-escape catalogue, less
        # those that return an Enumerator keeping the block (`chunk`, `slice_when`, …); the block forms of the
        # String match methods; and the Kernel and eval-family functions that run the block at once. So do the
        # names that follow the iterator convention by their `each_` prefix (`each_section { |s| … }`).
        RUNS_BLOCK_NOW = (
          ClosureEscapeAnalyzer::ENUMERABLE_NON_ESCAPING - ClosureEscapeAnalyzer::DEFERRED_ENUMERATOR_METHODS +
          ClosureEscapeAnalyzer::OBJECT_NON_ESCAPING + ClosureEscapeAnalyzer::ARRAY_EXTRA +
          ClosureEscapeAnalyzer::HASH_EXTRA + ClosureEscapeAnalyzer::RANGE_EXTRA +
          ClosureEscapeAnalyzer::INTEGER_EXTRA + ClosureEscapeAnalyzer::IO_ITERATION +
          ClosureEscapeAnalyzer::IO_SINGLETON_ITERATION +
          %i[
            sub sub! gsub gsub! scan grep grep_v
            loop catch open instance_eval instance_exec class_eval class_exec module_eval module_exec
          ]
        ).to_set.freeze
        private_constant :RUNS_BLOCK_NOW

        module_function

        # True when `node`, a call or a `super`, may keep its block: a call that stores it ({StoredBlockCall}:
        # `lambda`, `proc`, `Proc.new`, `define_method`, …), a call on a lazy enumerator, `super`, which hands it to
        # the superclass's method, or any call outside {RUNS_BLOCK_NOW}.
        def kept?(node)
          return true unless node.is_a?(Prism::CallNode)
          return true if StoredBlockCall.stores_block?(node) || lazy_receiver?(node.receiver)

          name = node.name
          !RUNS_BLOCK_NOW.include?(name) && !name.start_with?("each_")
        end

        # `items.lazy.map { … }` keeps the block until the enumerator is forced.
        def lazy_receiver?(receiver)
          while receiver.is_a?(Prism::CallNode)
            return true if receiver.name == :lazy

            receiver = receiver.receiver
          end
          false
        end
        private_class_method :lazy_receiver?
      end
    end
  end
end
