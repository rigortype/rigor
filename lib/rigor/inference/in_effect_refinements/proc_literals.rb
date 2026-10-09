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

        module_function

        # The node whose span is the body `node.refined(…)` applies to: `node` itself for a lambda literal, or the
        # literal block of a bare `proc` / `lambda` call or of `Proc.new`; nil for anything else. A Proc held in a
        # variable, or one passed as `&blk`, is not one: which block it holds is not syntax.
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
          node.receiver.nil? && BARE_PROC_CALLS.include?(node.name)
        end

        def proc_new_call?(node)
          receiver = node.receiver
          node.name == :new &&
            (receiver.is_a?(Prism::ConstantReadNode) ||
              (receiver.is_a?(Prism::ConstantPathNode) && receiver.parent.nil?)) &&
            receiver.name == :Proc
        end
      end
    end
  end
end
