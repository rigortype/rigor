# frozen_string_literal: true

require "prism"

require_relative "../../source/node_children"

module Rigor
  module Inference
    module MatchRebinding
      # The frame a body runs in, stamped on its entry scope ({Scope#with_match_frame}) and shared by every scope
      # derived from it, blocks included, since they run in the same frame. Each answer is computed on the first
      # ask — only code run while a match global is narrowed asks — and kept for the rest of the body: whether the
      # body makes a matching closure, the method's forwarded `&block` name, and {MatchRebinding.may_match?} per
      # node ({#memo}).
      class Frame
        # The nodes that bind a local in a body: the writes, and a block's, lambda's, `rescue`'s or pattern's own
        # parameters and targets.
        LOCAL_BINDINGS = Set[
          Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
          Prism::LocalVariableAndWriteNode, Prism::LocalVariableTargetNode, Prism::RequiredParameterNode,
          Prism::OptionalParameterNode, Prism::RestParameterNode, Prism::RequiredKeywordParameterNode,
          Prism::OptionalKeywordParameterNode, Prism::KeywordRestParameterNode, Prism::BlockParameterNode,
          Prism::BlockLocalVariableNode
        ].freeze
        private_constant :LOCAL_BINDINGS

        # @param parameters — a method's parameters, whose default expressions run in its frame; nil for a class,
        #   module or file body.
        def initialize(body, parameters = nil)
          @body = body
          @parameters = parameters
          @matching_closure = nil
          @forwarded_block = nil
          @scans = nil
        end

        def matching_closure?(scope = nil)
          if @matching_closure.nil?
            @matching_closure = MatchRebinding.matching_closure?(@body, scope) ||
                                MatchRebinding.matching_closure?(@parameters, scope)
          end
          @matching_closure
        end

        # True when `name` is the method's own `&block` parameter and the body never binds that name — no write, no
        # block or lambda parameter shadowing it — so every read of it in the frame is the block the caller passed,
        # which the caller made in its own frame.
        def forwarded_block?(name)
          @forwarded_block = forwarded_block_name || false if @forwarded_block.nil?
          @forwarded_block == name
        end

        # True when `name` is the method's own `&block` parameter, whatever the body does with it: calling it runs
        # the block the caller passed, which may be a C-function proc ({MatchRebinding.frame_call_matches?}).
        def block_parameter?(name)
          parameters = @parameters
          parameters.is_a?(Prism::ParametersNode) && parameters.block&.name == name
        end

        # The scan of `node` under `scope`, kept while `scope`'s local and instance-variable tables are the same
        # objects: a lookup argument's answer reads them ({MatchRebinding.may_match?}), and a rebuild that leaves
        # them alone passes the same tables on.
        def memo(node, scope)
          scans = (@scans ||= {}.compare_by_identity)
          locals = scope.locals
          ivars = scope.ivars
          kept = scans[node]
          return kept[2] if kept && kept[0].equal?(locals) && kept[1].equal?(ivars)

          result = yield
          scans[node] = [locals, ivars, result]
          result
        end

        private

        def forwarded_block_name
          parameters = @parameters
          block = parameters.is_a?(Prism::ParametersNode) ? parameters.block : nil
          name = block&.name
          return nil if name.nil? || binds_local?(@body, name)

          name
        end

        # `node` is a body or one of its descendants; a method with an empty body passes nil.
        def binds_local?(node, name)
          return false if node.nil?
          return true if LOCAL_BINDINGS.include?(node.class) && node.name == name
          return false if OWN_FRAME_NODES.include?(node.class)

          found = false
          node.rigor_each_child { |child| found ||= binds_local?(child, name) }
          found
        end
      end
    end
  end
end
