# frozen_string_literal: true

require "prism"

require_relative "../../inference/attribute_reader_chain"
require_relative "../../source/node_children"

module Rigor
  module Analysis
    module CheckRules
      # Issue #2685 — whether an expression reads an attribute chain `x.r` whose type a truthiness or `nil?` guard
      # narrowed ({Inference::AttributeReaderChain}), so the rules that conclude a check is redundant from a
      # narrowed type must withhold their firing.
      #
      # That narrowing assumes nothing between the guard and the read writes the attribute, and some writes are
      # invisible to it: an alias of the root (`y = x; y.r = nil`), a callee handed the root (`mutate(x)`). A wrong
      # narrowing must cost a missed `nil` report at most, never a finding on correct code, so a fact of this kind
      # only refines types. `return 0 unless @task.done; refresh!; if @task.done … end` is the shape: were the
      # second test read against the guard's fact, it would be reported always truthy.
      #
      # Purely syntactic, in the shape of {PublishedConstantGuard}: the predicate's whole subtree is walked, and
      # it is rooted when any single-hop chain in it has a chain fact in `scope` and passes the attribute gate. An
      # `is_a?` fact on an attribute reader withholds too, the conservative direction. A copy of the read into a
      # local before the predicate (`v = x.r; if v`) is not followed.
      module AttributeChainGuard
        module_function

        # @return true when the rule MUST withhold its firing.
        def rooted?(node, scope)
          return false if node.nil? || scope.nil? || scope.method_chain_narrowings.empty?

          chain_fact?(node, scope) || any_child_rooted?(node, scope)
        end

        def any_child_rooted?(node, scope)
          node.rigor_each_child { |child| return true if rooted?(child, scope) }
          false
        end

        def chain_fact?(node, scope)
          return false unless node.is_a?(Prism::CallNode) && node.block.nil?
          return false unless node.arguments.nil? || node.arguments.arguments.empty?

          kind =
            case node.receiver
            when Prism::LocalVariableReadNode then :local
            when Prism::InstanceVariableReadNode then :ivar
            end
          return false if kind.nil? || scope.method_chain_narrowing(kind, node.receiver.name, node.name).nil?

          Inference::AttributeReaderChain.attribute_read?(node, scope)
        end
      end
    end
  end
end
