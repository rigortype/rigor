# frozen_string_literal: true

require "prism"

require_relative "../source/node_walker"
require_relative "block_parameter_binder"

module Rigor
  module Inference
    # The outer locals a block body can REBIND — the one name set that ADR-56's captured-local write-back
    # (`StatementEvaluator#write_back_block_captures`), the escaping-block narrowing drop
    # (`StatementEvaluator#drop_captured_narrowing`) and issue #587's per-element fold
    # (`ExpressionTyper#per_element_captured_bindings`) all key on. It lives in one place so the four
    # cannot disagree about what "captured" means.
    #
    # A write counts across every local-write form — plain `=` (`LocalVariableWriteNode`), the operator /
    # `||=` / `&&=` compound forms, and a multi-assign target (`x, y = …` → `LocalVariableTargetNode` under
    # a `MultiWriteNode`) — at ANY depth: a block is a closure, so a write inside a nested block binds the
    # same outer variable. Block-introduced names (parameters, numbered parameters, `;`-locals) and names
    # not bound in the outer scope are excluded; a write to either is not a captured rebind of an outer
    # variable.
    #
    # {.ivar_writes} is the instance-variable sibling, which the write-back, the drop and the per-element fold
    # read beside it. Its names keep their `@`, so a map over both sets never collides, and {.bound_type} /
    # {.bind} reach each name through its own kind of binding.
    module CapturedLocals
      LOCAL_WRITE_NODES = [
        Prism::LocalVariableWriteNode,
        Prism::LocalVariableOperatorWriteNode,
        Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode,
        Prism::LocalVariableTargetNode
      ].freeze

      IVAR_WRITE_NODES = [
        Prism::InstanceVariableWriteNode,
        Prism::InstanceVariableOperatorWriteNode,
        Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode,
        Prism::InstanceVariableTargetNode
      ].freeze

      module_function

      # @param base_scope — the call-site scope the block closes over.
      # @return the captured names the body writes, each once, in first-write order.
      def writes(block_node, base_scope)
        body = block_node.body
        return [] if body.nil?

        introduced = introduced_locals(block_node)
        outer_writes = []
        Source::NodeWalker.each(body) do |descendant|
          next unless LOCAL_WRITE_NODES.any? { |klass| descendant.is_a?(klass) }
          next if introduced.include?(descendant.name)
          next unless base_scope.locals.key?(descendant.name)

          outer_writes << descendant.name
        end
        outer_writes.uniq
      end

      # The instance variables the body writes, on the same terms as {.writes}: every ivar-write form, at any
      # depth, bound in `base_scope`. An ivar is not captured — the block shares the caller's `self` — but it
      # outlives an iteration exactly as a captured local does, which is all the per-element fold's
      # first-iteration pin needs. A block cannot introduce an ivar, so nothing is excluded on that ground;
      # one the call-site scope does not bind has no entry binding to pin. A nested block that rebinds `self`
      # (`instance_eval`) writes another object's ivar, which counts anyway: counting a name can only widen
      # its binding, never narrow it.
      #
      # @return `@`-prefixed names, each once, in first-write order.
      def ivar_writes(block_node, base_scope)
        body = block_node.body
        return [] if body.nil?

        ivars = []
        Source::NodeWalker.each(body) do |descendant|
          next unless IVAR_WRITE_NODES.any? { |klass| descendant.is_a?(klass) }
          next if base_scope.ivar(descendant.name).nil?

          ivars << descendant.name
        end
        ivars.uniq
      end

      # The binding `scope` holds for a name from {.writes} or {.ivar_writes}.
      def bound_type(scope, name)
        ivar_name?(name) ? scope.ivar(name) : scope.local(name)
      end

      # `scope` with a name from {.writes} or {.ivar_writes} bound to `type`.
      def bind(scope, name, type)
        ivar_name?(name) ? scope.with_ivar(name, type) : scope.with_local(name, type)
      end

      # Ruby spells every instance variable with a leading `@` and no local with one.
      def ivar_name?(name) = name.start_with?("@")

      # Names the block itself introduces: parameters (numbered parameters included, via
      # `BlockParameterBinder`) plus the explicit `;`-prefixed block-locals on `BlockParametersNode`.
      def introduced_locals(block_node)
        introduced = Set.new(BlockParameterBinder.new.bind(block_node).keys)
        params_root = block_node.parameters
        params_root.locals.each { |loc| introduced << loc.name } if params_root.is_a?(Prism::BlockParametersNode)
        introduced
      end
    end
  end
end
