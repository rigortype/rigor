# frozen_string_literal: true

require "prism"

require_relative "alias_mutation_floor"
require_relative "deep_erasure"
require_relative "mutation_widening"
require_relative "opaque_mutation"
require_relative "receiver_alias"
require_relative "refinement_mutation"
require_relative "remover_holder_scan"
require_relative "set_mutation"

module Rigor
  module Inference
    # Issue #3340 — whether a closure that may run later can empty a local's collection. An emptiness guard's
    # `non-empty-array[T]` is a fact about the object, and a closure made before the guard may run after it
    # (`f = -> { xs.clear }; return if xs.empty?; f.call`): the widening at the closure is undone by the guard, and
    # nothing ties a later call to the closure. So the guard does not narrow such a local at all
    # (`Narrowing::PresencePredicates`), the rule the remover narrowing takes for a local a later-running closure
    # references ({RemoverHolderScan}).
    #
    # A closure is a lambda literal or a block that may run after its call returns
    # ({RemoverHolderScan.deferred_block?}: `proc`, `lambda`, `define_method`, `define_singleton_method`, any block
    # but a catalogued iterator's or `tap` / `then` / `yield_self`'s, so a `loop` block too), anywhere in the frame
    # body the guard runs in, so one made in a scope enclosing the guard counts. A closure the guard itself sits in
    # does not: its own statements run in order, and the straight-line rules read them. That assumes the closure
    # does not call itself, which would re-enter it past the guard.
    #
    # It can empty the local when its body, a nested block included, runs on a read of it that resolves outside the
    # closure: a mutator that can leave a non-empty receiver empty (every {MUTATORS} name but the ones
    # {RefinementMutation.preserves_witness?} keeps, so `<<` and `sort!` do not count), spelled directly, through a
    # literal `send` or a literal-named `Method` object, or by a symbol block over a literal Array holding it; or an
    # opaque hand-off ({OpaqueMutation}: a computed `send`, `instance_eval`, a `yield` passing it). A closure that
    # only reads the local, or only appends to it, leaves the guard's narrowing alone, and so does a block that ran
    # and finished before the guard. Not read: a holder of the object made outside the closure (`ys = xs; f = -> {
    # ys.clear }`), an alias made inside it, a callee the closure passes the local to, and an emptier behind a call
    # that hands the receiver back (`xs.tap(&:clear)`).
    module DeferredMutation
      MUTATORS = (MutationWidening::SHAPE_MUTATORS | SetMutation::MUTATORS).freeze
      SCOPE_NODES = Set[Prism::BlockNode, Prism::LambdaNode].freeze
      private_constant :MUTATORS, :SCOPE_NODES

      module_function

      # True when a closure in `scope`'s frame body that may run later, and that does not hold `guard`, can empty
      # the Array the local `name` holds.
      def empties?(scope, name, guard)
        body = scope.match_frame&.body
        return false if body.nil?

        closure_emptier?(body, name.to_sym, 0, nil, guard.location.start_offset)
      end

      # `depth` counts the blocks and lambdas entered from the outermost later-running closure on, that one
      # included; zero outside every such closure. A read at `depth` names the frame's local when it resolves that
      # many scopes out, which a read inside a nested `def` or class body never does.
      def closure_emptier?(node, name, depth, parent, guard_offset)
        klass = node.class
        if SCOPE_NODES.include?(klass)
          depth += 1 if depth.positive? || later_closure?(node, parent, guard_offset)
        elsif depth.positive? && emptier?(node, name, depth)
          return true
        end
        found = false
        node.rigor_each_child { |child| found ||= closure_emptier?(child, name, depth, node, guard_offset) }
        found
      end

      # A lambda literal, or a block that may run after its call returns, that does not hold the guard. A `loop`
      # block counts: the name is no catalogued iterator's, a project may define it and keep the block, and the
      # entry of a `Kernel#loop` body reads only the mutators the body spells on the local.
      def later_closure?(node, parent, guard_offset)
        return false unless node.is_a?(Prism::LambdaNode) || RemoverHolderScan.deferred_block?(parent)

        location = node.location
        guard_offset < location.start_offset || guard_offset >= location.end_offset
      end

      def emptier?(node, name, depth)
        return names?(OpaqueMutation.local_arguments(node.arguments&.arguments || []), name, depth) if yield?(node)
        return false unless node.is_a?(Prism::CallNode)

        receiver = emptied_receiver(node)
        return true if receiver && names?(ReceiverAlias.mutated_reads(receiver), name, depth)

        symbol_block_emptier?(node, name, depth)
      end

      def yield?(node) = node.is_a?(Prism::YieldNode)

      # The receiver `call_node` may empty: its own under an emptying mutator, spelled directly or as the call a
      # literal `send` or a literal-named `Method` object makes, or the one it hands to unread code.
      def emptied_receiver(call_node)
        made = AliasMutationFloor.literal_send_target(call_node) || OpaqueMutation.method_object_target(call_node) ||
               call_node
        return made.receiver if emptying?(made.name)

        OpaqueMutation.opaque_receiver(call_node)
      end

      def emptying?(method_name)
        MUTATORS.include?(method_name) && !RefinementMutation.preserves_witness?("Array", method_name)
      end

      # `[xs, ys].each(&:clear)`: a symbol block naming an emptying mutator over a literal Array holding the local.
      def symbol_block_emptier?(call_node, name, depth)
        receiver = call_node.receiver
        return false unless receiver.is_a?(Prism::ArrayNode) && DeepErasure.symbol_proc_mutation?(call_node.block)
        return false unless emptying?(call_node.block.expression.unescaped.to_sym)

        receiver.elements.any? { |element| names?(ReceiverAlias.mutated_reads(element), name, depth) }
      end

      def names?(reads, name, depth)
        reads.any? { |read| read.is_a?(Prism::LocalVariableReadNode) && read.name == name && read.depth >= depth }
      end
    end
  end
end
