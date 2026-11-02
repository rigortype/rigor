# frozen_string_literal: true

require "prism"

require_relative "../run_scoped_slots"
require_relative "closure_escape_analyzer"

module Rigor
  module Inference
    # Issue #2608, review round 1 of #2621 — which bindings of a body another holder may write, so a remover on them
    # is not narrowed ({RemoverNarrowing}): a write through that holder after the call would outlive the narrowing.
    module RemoverHolderScan
      # The holders the body scan sees: a closure that may run later (a lambda, or a block passed to a call that is
      # not a catalogued iterator or `tap` / `then` / `yield_self`, such as `proc { l << 1 }`), a copy of the binding
      # into another variable (`al = l`, `@x = l`, `a, b = l, 1`, or the receiver itself being such a copy), a
      # reflective call on it (`l.send(...)`, `l.instance_eval { }`, `l.tap { }`), and `binding` / `eval` anywhere in
      # the body. A container, an argument and a method of another object stay unseen (issue #2335 tracks aliases).
      REFLECTIVE_CALLS = %i[
        send public_send __send__ instance_eval instance_exec tap then yield_self itself method
        define_singleton_method extend
      ].to_set.freeze
      IMMEDIATE_BLOCK_CALLS = %i[tap then yield_self].to_set.freeze
      FRAME_CALLS = %i[binding eval local_variable_set instance_variable_set].to_set.freeze
      VARIABLE_READS = [Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode].freeze
      VARIABLE_REFERENCES = [
        Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode,
        Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode, Prism::LocalVariableTargetNode,
        Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode,
        Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableTargetNode
      ].freeze
      COPYING_WRITES = [
        Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode, Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode,
        Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode, Prism::ClassVariableWriteNode,
        Prism::ClassVariableOrWriteNode, Prism::GlobalVariableWriteNode, Prism::GlobalVariableOrWriteNode,
        Prism::ConstantWriteNode, Prism::ConstantOrWriteNode
      ].freeze
      NAMED_WRITES = [
        Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode, Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode,
        Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode
      ].freeze
      ALL = :all
      # A run-scoped slot ({RunScopedSlots}): emptied when a run ends, so no verdict outlives the body it read.
      UNSAFE_CACHE_KEY = RunScopedSlots.register(:__rigor_remover_narrowing_unsafe)
      private_constant :REFLECTIVE_CALLS, :IMMEDIATE_BLOCK_CALLS, :FRAME_CALLS, :VARIABLE_READS, :VARIABLE_REFERENCES,
                       :COPYING_WRITES, :NAMED_WRITES, :ALL, :UNSAFE_CACHE_KEY

      module_function

      # Whether the binding `name` (a local, or an `@ivar`) may be written through another holder somewhere in the
      # body `scope` runs, by one flow-insensitive scan per body. A scope with no known body answers true.
      def unsafe_receiver?(scope, name)
        body = scope.match_frame&.body
        return true if body.nil?

        table = (Thread.current[UNSAFE_CACHE_KEY] ||= ObjectSpace::WeakKeyMap.new)
        names = table[body] ||= unsafe_names(body)
        names.equal?(ALL) || names.include?(name.to_sym)
      end

      def unsafe_names(body)
        names = Set.new
        catch(ALL) do
          collect_unsafe(body, false, names)
          return names.freeze
        end
        ALL
      end

      def collect_unsafe(node, in_closure, names) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        case node
        when Prism::CallNode
          throw ALL if node.receiver.nil? && FRAME_CALLS.include?(node.name)

          record_reflective(node, names)
        when Prism::LambdaNode then in_closure = true
        when Prism::MultiWriteNode then copied_names(node.value).each { |n| names << n } if node.value
        end
        names << node.name if in_closure && VARIABLE_REFERENCES.any? { |k| node.is_a?(k) }
        record_copy(node, names) if COPYING_WRITES.any? { |k| node.is_a?(k) }

        node.compact_child_nodes.each do |child|
          child_in_closure = in_closure || (child.is_a?(Prism::BlockNode) && deferred_block?(node))
          collect_unsafe(child, child_in_closure, names)
        end
      end

      def record_reflective(call_node, names)
        receiver = unparenthesised(call_node.receiver)
        return unless VARIABLE_READS.any? { |k| receiver.is_a?(k) } && REFLECTIVE_CALLS.include?(call_node.name)

        names << receiver.name
      end

      def record_copy(node, names)
        copied = copied_names(node.value)
        return if copied.empty?

        copied.each { |n| names << n }
        names << node.name if NAMED_WRITES.any? { |k| node.is_a?(k) }
      end

      # The variables a written value hands on: a bare read, or a read among an Array literal's elements (a multiple
      # assignment's right-hand side).
      def copied_names(value)
        value = unparenthesised(value)
        return [value.name] if VARIABLE_READS.any? { |k| value.is_a?(k) }
        return [] unless value.is_a?(Prism::ArrayNode)

        value.elements.filter_map do |element|
          element = element.expression if element.is_a?(Prism::SplatNode)
          element.name if VARIABLE_READS.any? { |k| element.is_a?(k) }
        end
      end

      def unparenthesised(node)
        while node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode) && node.body.body.size == 1
          node = node.body.body.first
        end
        node
      end

      # A block that may run after its call returns: any but a catalogued iterator's, or `tap` / `then` /
      # `yield_self`'s.
      def deferred_block?(call_node)
        return true unless call_node.is_a?(Prism::CallNode)

        !(ClosureEscapeAnalyzer.iterator_name?(call_node.name) || IMMEDIATE_BLOCK_CALLS.include?(call_node.name))
      end
    end
  end
end
