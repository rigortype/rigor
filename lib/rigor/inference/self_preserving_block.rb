# frozen_string_literal: true

require "prism"

require_relative "closure_escape_analyzer"
require_relative "project_method_ownership"

module Rigor
  module Inference
    # Issue #2861 — whether a block-carrying call provably runs its literal block under the CALLER's `self`, so the
    # block body is no more opaque than the scope around it (`Scope#entering_self_preserving_block`).
    #
    # Issue #316 enters every block with `self` unmodelled, because a DSL call (`RSpec.describe`, `Class.new`, a
    # project `def run(&b) = instance_exec(&b)`) may run the block on another object, and the call cannot be told
    # apart from `Array#each` without knowing the callee. Here the callee is known: the explicit receiver's type and
    # method are one {ClosureEscapeAnalyzer} classifies as `:non_escaping` — a catalogued core iterator, `tap` /
    # `then`, or a project class's inherited `Enumerable` method — each of which `yield`s, which runs the block
    # with its own `self`. The project must not define the method anywhere the receiver looks it up
    # ({ProjectMethodOwnership.defines?}): a project reopening of `Array#each` could `instance_exec` the block.
    #
    # A receiverless or `self.` call is the DSL shape and never answers true, nor does a receiver Rigor cannot see.
    module SelfPreservingBlock
      module_function

      # `classification` is the receiver's {ClosureEscapeAnalyzer.classify} answer when the caller already holds it.
      def call?(call_node, receiver_type, scope, classification: nil)
        return false unless call_node.is_a?(Prism::CallNode) && call_node.block.is_a?(Prism::BlockNode)

        receiver = call_node.receiver
        return false if receiver.nil? || receiver.is_a?(Prism::SelfNode) || receiver_type.nil?

        method_name = call_node.name
        classification ||= ClosureEscapeAnalyzer.classify(receiver_type: receiver_type, method_name: method_name,
                                                          scope: scope)
        return false unless classification == :non_escaping

        targets = ProjectMethodOwnership.targets(receiver_type)
        return false if targets.nil? || targets.empty?

        targets.none? { |class_name, kind| ProjectMethodOwnership.defines?(class_name, method_name, kind, scope) }
      rescue StandardError
        false
      end
    end
  end
end
