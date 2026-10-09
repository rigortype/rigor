# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    class InEffectRefinements
      # Issue #1666 — the Proc literals whose body a `.refined` receiver call applies to, recognised from syntax.
      module ProcLiterals
        # The `Kernel` calls whose literal block is the Proc they return.
        BARE_PROC_CALLS = %i[proc lambda].freeze
        private_constant :BARE_PROC_CALLS

        # Copies that keep a refined Proc's refinements (`test_refined_preserved_by_dup`): a chain reads through them.
        COPY_CALLS = %i[dup clone].freeze
        private_constant :COPY_CALLS

        module_function

        # `[literal, refined calls]` for the outermost `.refined` call `node`: the Proc literal the chain starts from
        # ({.refinable}, or nil), and every `.refined` call of the chain, innermost (first called) first. The chain
        # reads through parentheses and through `dup` / `clone`.
        def refined_chain(node)
          calls = [node]
          receiver = unwrap(node.receiver)
          loop do
            if refined_call?(receiver)
              calls << receiver
            elsif !copy_call?(receiver)
              break
            end
            receiver = unwrap(receiver.receiver)
          end
          [refinable(receiver), calls.reverse]
        end

        def refined_call?(node) = node.is_a?(Prism::CallNode) && node.name == :refined

        def copy_call?(node)
          node.is_a?(Prism::CallNode) && COPY_CALLS.include?(node.name) && node.arguments.nil? && node.block.nil? &&
            !node.receiver.nil?
        end

        # `( expr )` with one statement reads as `expr`.
        def unwrap(node)
          while node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode) &&
                node.body.body.size == 1
            node = node.body.body.first
          end
          node
        end

        # The node whose span is the body `node.refined(…)` applies to: `node` itself for a lambda literal, or the
        # literal block of a `proc` / `lambda` call on no receiver or on `Kernel`, or of `Proc.new`; nil for anything
        # else. A Proc held in a variable, or one passed as `&blk`, is not one: which block it holds is not syntax.
        def refinable(node)
          case node
          when Prism::LambdaNode then node
          when Prism::CallNode
            block = node.block
            return nil unless block.is_a?(Prism::BlockNode)

            block if bare_proc_call?(node) || proc_new_call?(node)
          end
        end

        def bare_proc_call?(node)
          BARE_PROC_CALLS.include?(node.name) && (node.receiver.nil? || top_constant?(node.receiver, :Kernel))
        end

        def proc_new_call?(node)
          node.name == :new && top_constant?(node.receiver, :Proc)
        end

        # `Name` or `::Name`.
        def top_constant?(node, name)
          (node.is_a?(Prism::ConstantReadNode) || (node.is_a?(Prism::ConstantPathNode) && node.parent.nil?)) &&
            node.name == name
        end
      end
    end
  end
end
