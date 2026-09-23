# frozen_string_literal: true

require "prism"

require_relative "../source/node_walker"
require_relative "block_parameter_binder"
require_relative "index_write_widening"
require_relative "mutation_widening"
require_relative "receiver_alias"

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
    # The per-element fold also asks for the instance variables the body rebinds (`ivars: true`). Their
    # names keep their `@`, so a map over both kinds never collides, and {.bound_type} / {.bind} reach each
    # name through its own kind of binding.
    #
    # {.content_mutations} is the sibling set on the same terms: the captured outer locals the body mutates
    # IN PLACE rather than rebinds, which the rebind set cannot see and the per-element fold needs as well.
    module CapturedLocals
      LOCAL_WRITE_NODES = Set[
        Prism::LocalVariableWriteNode,
        Prism::LocalVariableOperatorWriteNode,
        Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode,
        Prism::LocalVariableTargetNode
      ].freeze

      IVAR_WRITE_NODES = Set[
        Prism::InstanceVariableWriteNode,
        Prism::InstanceVariableOperatorWriteNode,
        Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode,
        Prism::InstanceVariableTargetNode
      ].freeze

      module_function

      # @param base_scope — the call-site scope the block closes over.
      # @param ivars — also collect the instance variables the body rebinds, for the per-element fold. An
      #   ivar is not captured — the block shares the caller's `self` — but it outlives an iteration exactly
      #   as a captured local does. It counts on the same terms as a local (every write form, any depth, bound
      #   in `base_scope`), except that one still on its class-wide binding does not: ADR-58's declaration
      #   seed is the union of every write in the class, this body's included, so there is no first-iteration
      #   pin in it to remove. A nested block that rebinds `self` (`o.instance_eval`) writes another object's
      #   ivar, and a nested `def` runs only when called; both still count, because an `instance_eval` without
      #   a receiver, or a call to that `def` inside the body, does write this one.
      # @return the captured names the body writes, each once, in first-write order.
      def writes(block_node, base_scope, ivars: false)
        body = block_node.body
        return [] if body.nil?

        introduced = introduced_locals(block_node)
        names = []
        Source::NodeWalker.each(body) do |descendant|
          if LOCAL_WRITE_NODES.include?(descendant.class)
            next if introduced.include?(descendant.name)
            next unless base_scope.locals.key?(descendant.name)
          else
            next unless ivars && IVAR_WRITE_NODES.include?(descendant.class)
            next unless rebindable_ivar?(base_scope, descendant.name)
          end

          names << descendant.name
        end
        names.uniq
      end

      def rebindable_ivar?(scope, name)
        !scope.ivar(name).nil? && !scope.declaration_sourced?(:ivar, name)
      end

      # The binding `scope` holds for a name from {.writes}.
      def bound_type(scope, name)
        ivar_name?(name) ? scope.ivar(name) : scope.local(name)
      end

      # `scope` with a name from {.writes} bound to `type`, keeping the name's optimistic nil-freeness mark
      # (issue #286). `Scope#with_local` / `#with_ivar` drop it as a fresh write should, but here `type`
      # stands for the binding across iterations, and a value that was nil-free only optimistically still is:
      # without the mark `x.nil?` folds to `false` where the runtime answers `true`.
      def bind(scope, name, type)
        if ivar_name?(name)
          scope.with_ivar(name, type).with_optimistic_ivar(name, scope.optimistic_ivar(name))
        else
          scope.with_local(name, type).with_optimistic_local(name, scope.optimistic_local(name))
        end
      end

      # Ruby spells every instance variable with a leading `@` and no local with one.
      def ivar_name?(name) = name.start_with?("@")

      # The nodes that change a receiver's CONTENT without rebinding it: a call to a name the straight-line
      # widening responds to ({MutationWidening::SHAPE_MUTATORS}), and the index writes that store through
      # `[]=` without being a `[]=` call ({IndexWriteWidening::CONTENT_WRITE_NODE_CLASSES}, the one list the
      # block-return threading gate and the captured-local write-back read too).
      INDEX_STORE_NODES = IndexWriteWidening::CONTENT_WRITE_NODE_CLASSES
      private_constant :INDEX_STORE_NODES

      # The captured outer locals the body mutates in place, each mapped to its mutation sites (the nodes
      # above) in source order. A site counts through every variable its receiver can evaluate to
      # ({ReceiverAlias.candidates}), at any nesting depth as long as a local's read resolves past every nested
      # block ({.outer_read?}), and a local is excluded on exactly the terms {.writes} excludes it.
      #
      # Under `ivars: true` the instance variables the body mutates in place count too, on the terms {.writes}
      # takes a rebound one ({.rebindable_ivar?}). Since the block-return threading gate threads an index write,
      # `@cache[:first] ||= e; @cache[:first] == 2` would otherwise type every position from the empty entry
      # hash, store THAT position's `e`, and fold `find` to `2` where Ruby, keeping the first iteration's `1`,
      # answers `nil`.
      #
      # @param base_scope — the call-site scope the block closes over.
      # @param ivars — also collect the instance variables the body mutates in place.
      # @return `{ name => [site, ...] }`, empty for the overwhelmingly common body that mutates nothing
      #   captured.
      def content_mutations(block_node, base_scope, ivars: false)
        body = block_node.body
        return {} if body.nil?

        introduced = nil
        sites = {}
        Source::NodeWalker.each_with_ancestors(body) do |descendant, ancestors|
          receiver = mutated_receiver(descendant)
          next if receiver.nil?

          ReceiverAlias.candidates(receiver).each do |read|
            next unless content_target?(read, base_scope, ivars)

            if read.is_a?(Prism::LocalVariableReadNode)
              next unless outer_read?(read, ancestors)

              introduced ||= introduced_locals(block_node)
              next if introduced.include?(read.name)
            end

            (sites[read.name] ||= []) << descendant
          end
        end
        sites
      end

      # A local bound at the call site (the block's own names are excluded by the caller), or — under `ivars:` —
      # an instance variable {.rebindable_ivar?} accepts.
      def content_target?(read, base_scope, ivars)
        return base_scope.locals.key?(read.name) if read.is_a?(Prism::LocalVariableReadNode)

        ivars && rebindable_ivar?(base_scope, read.name)
      end

      # True when `read` reaches past every block nested between the body and the mutation site. A read Prism
      # resolves inside a nested block's own scope (`[[9]].each { |a| a << x }`) names that block's parameter,
      # not the outer local that happens to share its name.
      def outer_read?(read, ancestors)
        nesting = ancestors.count { |node| node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode) }
        read.depth > nesting
      end

      def mutated_receiver(node)
        case node
        when Prism::CallNode then node.receiver if MutationWidening::SHAPE_MUTATORS.include?(node.name)
        when *INDEX_STORE_NODES then node.receiver
        end
      end

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
