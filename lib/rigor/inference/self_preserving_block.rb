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
    # The project must not define it on `Object`, `Kernel` or another owner every receiver reaches either
    # ({.universally_defined?}). A receiverless call is the DSL shape and never answers true, nor does a receiver Rigor
    # cannot see. A `self.` receiver is read like any other explicit one, through its type.
    module SelfPreservingBlock
      module_function

      # `classification` is the receiver's {ClosureEscapeAnalyzer.classify} answer when the caller already holds it.
      def call?(call_node, receiver_type, scope, classification: nil)
        return false unless call_node.is_a?(Prism::CallNode) && call_node.block.is_a?(Prism::BlockNode)

        return false if call_node.receiver.nil? || receiver_type.nil?

        method_name = call_node.name
        classification ||= ClosureEscapeAnalyzer.classify(receiver_type: receiver_type, method_name: method_name,
                                                          scope: scope)
        return false unless classification == :non_escaping

        targets = ProjectMethodOwnership.targets(receiver_type)
        return false if targets.nil? || targets.empty?
        return false if universally_defined?(method_name, scope)

        targets.none? { |class_name, kind| ProjectMethodOwnership.defines?(class_name, method_name, kind, scope) }
      rescue StandardError
        false
      end

      # The classes every receiver's lookup reaches: an instance of any class is an `Object` (a class object is also
      # a `Module` and a `Class`), so a project method of the name on one of them, or on `Kernel`, which
      # {ProjectMethodOwnership.defines?} reaches through `Object`'s ancestry, may be the one the call runs, whatever
      # class the receiver names. `ClosureEscapeAnalyzer` answers `tap` / `then` / `yield_self` for every class
      # without asking who defines them.
      UNIVERSAL_OWNERS = %w[Object Module Class].freeze
      private_constant :UNIVERSAL_OWNERS

      # Whether the project defines `method_name` on a {UNIVERSAL_OWNERS} entry. A top-level `def` of the name is
      # private, so an explicit-receiver call raises NoMethodError before any block runs, and is not counted.
      def universally_defined?(method_name, scope)
        UNIVERSAL_OWNERS.any? { |owner| ProjectMethodOwnership.defines?(owner, method_name, :instance, scope) }
      end
    end
  end
end
