# frozen_string_literal: true

require_relative "../../source/constant_path"

module Rigor
  module Inference
    class InEffectRefinements
      # The one walk of a file that records its activations, its refine-body `def`s and the `def`s a refine body
      # defines on its refined class ({InEffectRefinements} describes what each source contributes).
      module Walk
        private

        # `Module.nesting` inside `node`'s body while the block runs, for the refine-body defs recorded there.
        def within_nesting(node)
          outer = @nesting
          @nesting = Source::ConstantPath.pushed_nesting(outer, node.constant_path) || outer
          yield
        ensure
          @nesting = outer
        end

        # A file whose text names neither `using` nor `refine` (`refined` among it) holds none of the activations the
        # walk records, so the scan of the source string spares it the tree walk.
        def mentions_refinements?
          text = @root.send(:source).source
          text.include?("using") || text.include?("refine")
        end

        # `body` is the `[start, end]` of the body a `using` here stays in effect to the end of; `owner` is the name of
        # the module `self` is here, or nil where this walk cannot name it.
        def walk(node, prefix, body, in_def, owner)
          case node
          when Prism::ClassNode, Prism::ModuleNode
            inner = Source::ConstantPath.declaration_prefix(prefix, node.constant_path) || prefix
            return within_nesting(node) do
              walk_children(node.body, inner, span_of(node), false, inner.empty? ? nil : inner.join("::"))
            end
          when Prism::SingletonClassNode
            walk(node.expression, prefix, body, in_def, owner)
            return walk_children(node.body, prefix, span_of(node), false, nil)
          when Prism::DefNode
            return walk_children(node.body, prefix, body, true, nil)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
               Prism::ConstantPathOrWriteNode
            return if walked_meta_new_write?(node, prefix, body, in_def, owner)
          when Prism::BlockNode, Prism::LambdaNode
            return walk_children(node, prefix, body, in_def, nil)
          when Prism::CallNode
            record_call(node, prefix, body, in_def, owner)
          end

          walk_children(node, prefix, body, in_def, owner)
        end

        def walk_children(node, prefix, body, in_def, owner)
          return if node.nil?

          node.rigor_each_child { |child| walk(child, prefix, body, in_def, owner) }
        end

        # `M = Module.new do … end`: the block's `self` is the module the write names, so a `refine` in it refines
        # for `M`. The write's other parts walk as they would anyway.
        def walked_meta_new_write?(node, prefix, body, in_def, owner)
          call = ScopeIndexer.meta_new_block_call(node)
          return false if call.nil? || !ScopeIndexer.module_new_call?(call)

          named = meta_new_owner(node, prefix)
          walk(call.receiver, prefix, body, in_def, owner) if call.receiver
          walk_children(call.arguments, prefix, body, in_def, owner)
          record_call(call, prefix, body, in_def, owner)
          walk_children(call.block, prefix, body, in_def, named)
          true
        end

        def meta_new_owner(node, prefix)
          case node
          when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode then (prefix + [node.name.to_s]).join("::")
          else Source::ConstantPath.declaration_prefix(prefix, node.target)&.join("::")
          end
        end

        def record_call(node, prefix, body, in_def, owner)
          if (target = ScopeIndexer.refine_target(node))
            record_refine_block(node, owner, ScopeIndexer.constant_receiver_candidates(target, prefix))
          elsif using_call?(node) && !in_def
            record_using(node, prefix, body)
          elsif node.name == :refined
            record_refined_chain(node, prefix)
          end
        end

        # By `order`; activations a `.refined` chain recorded share the literal's offset and keep their recording (call)
        # order, so only then does the sort carry the index.
        def sort_activations
          if @chained_refined_calls.nil?
            @activations.sort_by!(&:order)
          else
            @activations = @activations.sort_by.with_index { |activation, index| [activation.order, index] }
          end
        end

        # ADR-121 WD1's `Proc#refined` source (#1666). The walk meets a chain's outermost `.refined` first, so it
        # records the whole chain from the literal outwards — the call order — and marks the inner calls done.
        def record_refined_chain(node, prefix)
          return if @chained_refined_calls&.include?(node)

          @chained_refined_calls ||= Set.new.compare_by_identity
          literal, chain = ProcLiterals.refined_chain(node)
          chain.each { |call| @chained_refined_calls << call }
          return if literal.nil?

          chain.each do |call|
            (call.arguments&.arguments || EMPTY).each do |argument|
              record_block_activation(literal, refined_argument_candidates(argument, prefix))
            end
          end
        end

        # A constant argument's lexical candidates, or nil ({UNKNOWN}) for any other argument: a local, a splat, a call.
        def refined_argument_candidates(argument, prefix)
          return nil unless argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode)

          candidates = ScopeIndexer.constant_receiver_candidates(argument, prefix)
          candidates.empty? ? nil : candidates
        end

        # An activation over a block's body (`block` a `Prism::BlockNode` or `Prism::LambdaNode`) that puts `names` in
        # effect after the block site's lexical list, each expanded through its includes as a `using`'s is; nil names
        # contribute {UNKNOWN}.
        def record_block_activation(block, names)
          start, stop = span_of(block)
          @activations << Activation.new(order: start, start: start, stop: stop, names: names, expand: true,
                                         refine_block: false)
        end

        def record_refine_block(node, owner, targets)
          start, stop = span_of(node.block)
          @activations << Activation.new(order: start, start: start, stop: stop, names: owner && [owner],
                                         expand: false, refine_block: true)
          body = node.block.body
          return if body.nil?

          ScopeIndexer.each_refinement_def(body) do |def_node|
            @refinement_defs << def_node.location.start_offset
            @refine_defs.record(owner, targets, def_node, @nesting) if owner
          end
        end

        def using_call?(node)
          node.name == :using && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
            node.arguments&.arguments&.size == 1
        end

        def record_using(node, prefix, body)
          argument = node.arguments.arguments.first
          order = node.location.end_offset
          candidates =
            if argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode)
              ScopeIndexer.constant_receiver_candidates(argument, prefix)
            end
          if candidates && !candidates.empty?
            @activations << Activation.new(order: order, start: order, stop: body.last, names: candidates,
                                           expand: true, refine_block: false)
          else
            @unresolved_using = true
            location = @root.location
            @activations << Activation.new(order: order, start: location.start_offset, stop: location.end_offset,
                                           names: nil, expand: false, refine_block: false)
          end
        end

        def span_of(node)
          location = node.location
          [location.start_offset, location.end_offset]
        end
      end
    end
  end
end
