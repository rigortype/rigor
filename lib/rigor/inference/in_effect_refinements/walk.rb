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

        # `body` is the `[start, end]` of the body a `using` here stays in effect to the end of; `context` is the
        # `RefineSelf::Context` of the `self` a `refine` here runs on, worked out by `RefineCensus`'s functions for
        # every body, method and block this walk enters. The census reads it back for each `refine`-shaped node
        # ({InEffectRefinements#refine_context}), so the two walks charge the same module.
        def walk(node, prefix, body, in_def, context)
          return if walked_body?(node, prefix, body, in_def, context)

          case node
          when Prism::SymbolNode
            record_refine_context(node, context) if RefineCensus.refine_symbol?(node)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
               Prism::ConstantPathOrWriteNode
            return if walked_meta_new_write?(node, prefix, body, in_def, context)
          when Prism::LambdaNode, Prism::BlockNode
            # A call's block walks under {#walk_block_call}; a `super` / `yield`-side block or a lambda may run
            # under any `self`.
            return walk_children(node, prefix, body, in_def, RefineSelf.unknown)
          when Prism::CallNode
            record_call(node, prefix, body, in_def, context)
            return walk_block_call(node, prefix, body, in_def, context) if node.block.is_a?(Prism::BlockNode)
          end

          walk_children(node, prefix, body, in_def, context)
        end

        # A `class` / `module` / `class << …` body or a `def` body, each with a `self` of its own.
        def walked_body?(node, prefix, body, in_def, context)
          case node
          when Prism::ClassNode, Prism::ModuleNode
            inner = Source::ConstantPath.declaration_prefix(prefix, node.constant_path) || prefix
            within_nesting(node) do
              walk_children(node.body, inner, span_of(node), false, declaration_context(node, inner))
            end
          when Prism::SingletonClassNode
            walk(node.expression, prefix, body, in_def, context)
            walk_children(node.body, prefix, span_of(node), false,
                          RefineSelf.singleton_class_body(context, node.expression.is_a?(Prism::SelfNode)))
          when Prism::DefNode
            walk_children(node.body, prefix, body, true, def_context(node, context))
          else
            return false
          end
          true
        end

        def declaration_context(node, inner)
          return RefineSelf.module_body(inner.empty? ? nil : inner.join("::")) if node.is_a?(Prism::ModuleNode)

          superclass = node.superclass
          module_superclass = (superclass.is_a?(Prism::ConstantReadNode) ||
                               (superclass.is_a?(Prism::ConstantPathNode) && superclass.parent.nil?)) &&
                              superclass.name == :Module
          RefineSelf.class_body(module_superclass)
        end

        # A `def` on no receiver is an instance method, `def self.x` (or `def M.x` inside `module M`) a singleton one;
        # one on any other object is defined on something the walk cannot name.
        def def_context(node, context)
          receiver = node.receiver
          return RefineSelf.method_body(context, false) if receiver.nil?
          return RefineSelf.method_body(context, true) if lexical_self_receiver?(receiver, context)

          RefineSelf.unknown.with(deferred: true)
        end

        def lexical_self_receiver?(receiver, context)
          return true if receiver.is_a?(Prism::SelfNode)

          here = context.here
          receiver.is_a?(Prism::ConstantReadNode) && here.is_a?(String) && here.split("::").last == receiver.name.to_s
        end

        # A block-carrying call: its receiver and arguments walk where the call is, its block under
        # `RefineSelf.block` (a `define_method` block is a method body, where `using` raises).
        def walk_block_call(node, prefix, body, in_def, context)
          walk(node.receiver, prefix, body, in_def, context) if node.receiver
          walk_children(node.arguments, prefix, body, in_def, context)
          block_context = RefineSelf.block(context, node, eval_receiver_name(node, prefix, context))
          walk_children(node.block, prefix, body, in_def || RefineSelf.method_block?(node), block_context)
        end

        # The module a `*_eval` / `*_exec` call's constant receiver names, resolved as the method walk resolves it
        # (`ScopeIndexer.eval_receiver_prefix`), or nil.
        def eval_receiver_name(node, prefix, context)
          return nil unless RefineCensus::SELF_EVAL_CALLS.include?(node.name) && !RefineCensus.self_call?(node)

          here = context.here
          self_prefix = here.is_a?(String) && here != RefineCensus.wildcard ? here.split("::") : []
          resolved = ScopeIndexer.eval_receiver_prefix(node, self_prefix, prefix, unnameable_self: self_prefix.empty?)
          resolved.join("::") unless resolved.nil? || resolved.empty?
        end

        # ADR-121 WD7 — what the census reads back for a `refine`-shaped node.
        def record_refine_context(node, context)
          @refine_contexts[node.location.start_offset] = context
        end

        def walk_children(node, prefix, body, in_def, context)
          return if node.nil?

          node.rigor_each_child { |child| walk(child, prefix, body, in_def, context) }
        end

        # `M = Module.new do … end`: the block's `self` is the module the write names, so a `refine` in it refines
        # for `M`. The write's other parts walk as they would anyway.
        def walked_meta_new_write?(node, prefix, body, in_def, context)
          call = ScopeIndexer.meta_new_block_call(node)
          return false if call.nil? || !ScopeIndexer.module_new_call?(call)

          named = meta_new_owner(node, prefix)
          walk(call.receiver, prefix, body, in_def, context) if call.receiver
          walk_children(call.arguments, prefix, body, in_def, context)
          record_call(call, prefix, body, in_def, context)
          walk_children(call.block, prefix, body, in_def, RefineSelf.module_body(named))
          true
        end

        def meta_new_owner(node, prefix)
          case node
          when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode then (prefix + [node.name.to_s]).join("::")
          else Source::ConstantPath.declaration_prefix(prefix, node.target)&.join("::")
          end
        end

        def record_call(node, prefix, body, in_def, context)
          record_refine_string_contexts(node, context)
          record_refine_context(node, context) if node.name == :refine
          owner = RefineSelf.charged_module(context)
          owner = nil if owner == RefineCensus.wildcard
          if context.here == RefineSelf::CLASS && ScopeIndexer.refine_call?(node)
            record_class_body_refine(node)
          elsif (target = ScopeIndexer.refine_target(node))
            record_refine_block(node, owner, ScopeIndexer.constant_receiver_candidates(target, prefix))
          elsif ScopeIndexer.refine_call?(node)
            # ADR-121 WD7 — a target the walk cannot name (`refine(k)`): the block is still a refine body, in effect
            # inside itself, with no class to file its defs under.
            record_refine_block(node, owner, EMPTY)
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

          ScopeIndexer.each_refinement_def(body) { |def_node| @refinement_defs << def_node.location.start_offset }
          return if owner.nil? || targets.empty?

          # ADR-121 WD7 (issue #1799) — a `def`, and an alias of a `def` the body wrote earlier; a later definer with no
          # body (`define_method`, `attr_*`, `undef`) clears the name, which then types as `Dynamic[top]`.
          RefineCensus.read_body(body).defs.each do |name, def_node|
            @refine_defs.record(owner, targets, name, def_node, @nesting)
          end
        end

        def record_class_body_refine(node) = (@class_body_refines ||= Set.new) << node.block.location.start_offset

        def record_refine_string_contexts(node, context)
          return unless RefineCensus.string_literal_call?(node)

          node.arguments&.arguments&.each do |argument|
            record_refine_context(argument, context) if RefineCensus.refine_string?(argument)
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
