# frozen_string_literal: true

require_relative "../../source/constant_path"

module Rigor
  module Inference
    class InEffectRefinements
      # The one walk of a file that records its activations, its refine-body `def`s and the `def`s a refine body
      # defines on its refined class ({InEffectRefinements} describes what each source contributes).
      module Walk
        METHOD_BLOCK_CALLS = %i[define_method define_singleton_method].freeze
        private_constant :METHOD_BLOCK_CALLS

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
        # the module `self` is here, or nil where this walk cannot name it; `class_self` is truthy where `self` is known
        # not to be a module that `refine` refines for (issue #1689): `true` in a plain class's body and methods (and a
        # `Class.new` block), `:module_class` in the body of a class whose superclass is `Module` (its instances are
        # modules), and `:module_singleton` in a module's `class << self` body (whose methods run on the module). A
        # block may run under another `self`, so it resets it; a `def` takes {#method_class_self}.
        def walk(node, prefix, body, in_def, owner, class_self)
          return if walked_body?(node, prefix, body, in_def, owner, class_self)

          case node
          when Prism::SymbolNode
            record_class_literal(node) if class_self == true && RefineCensus.refine_symbol?(node)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
               Prism::ConstantPathOrWriteNode
            return if walked_meta_new_write?(node, prefix, body, in_def, owner, class_self)
          when Prism::BlockNode, Prism::LambdaNode
            return walk_children(node, prefix, body, in_def, nil, false)
          when Prism::CallNode
            return if walked_class_new_call?(node, prefix, body, in_def, owner, class_self)
            return if walked_method_block?(node, prefix, body, owner, class_self)

            record_call(node, prefix, body, in_def, owner, class_self)
          end

          walk_children(node, prefix, body, in_def, owner, class_self)
        end

        # A `class` / `module` / `class << …` body or a `def` body, each with a `self` of its own.
        def walked_body?(node, prefix, body, in_def, owner, class_self)
          case node
          when Prism::ClassNode, Prism::ModuleNode
            inner = Source::ConstantPath.declaration_prefix(prefix, node.constant_path) || prefix
            within_nesting(node) do
              walk_children(node.body, inner, span_of(node), false, inner.empty? ? nil : inner.join("::"),
                            declaration_class_self(node))
            end
          when Prism::SingletonClassNode
            walk(node.expression, prefix, body, in_def, owner, class_self)
            walk_children(node.body, prefix, span_of(node), false, nil, class_self ? true : :module_singleton)
          when Prism::DefNode
            walk_children(node.body, prefix, body, true, nil, method_class_self(class_self, !node.receiver.nil?))
          else
            return false
          end
          true
        end

        # ADR-121 WD7 — `true` for a plain class's body, `:module_class` for one whose superclass is `Module`, false
        # for a module's.
        def declaration_class_self(node)
          return false unless node.is_a?(Prism::ClassNode)

          superclass = node.superclass
          module_superclass = (superclass.is_a?(Prism::ConstantReadNode) ||
                               (superclass.is_a?(Prism::ConstantPathNode) && superclass.parent.nil?)) &&
                              superclass.name == :Module
          module_superclass ? :module_class : true
        end

        # ADR-121 WD7 (M3) — the `class_self` of a method body written where `class_self` holds: a plain class's
        # methods, and a `Module` subclass's singleton methods, run on an object that is not a module, so a `refine`
        # there is the class's own method (true); a module's methods, its `class << self` methods and a `Module`
        # subclass's instance methods run on a module (false).
        def method_class_self(class_self, singleton)
          class_self == true || (class_self == :module_class && singleton)
        end

        # A `define_method` / `define_singleton_method` block is a method body (`using` raises in it), walked with the
        # `class_self` a `def` there would take.
        def walked_method_block?(node, prefix, body, owner, class_self)
          block = node.block
          return false unless block.is_a?(Prism::BlockNode) && METHOD_BLOCK_CALLS.include?(node.name) &&
                              RefineCensus.self_call?(node)

          walk(node.receiver, prefix, body, false, owner, class_self) if node.receiver
          walk_children(node.arguments, prefix, body, false, owner, class_self)
          walk_children(block, prefix, body, true, nil,
                        method_class_self(class_self, node.name == :define_singleton_method))
          true
        end

        # ADR-121 WD7 (M3) — a `:refine` literal, or a String naming it in an eval, `send` or method-naming call, where
        # `self` is a plain class or one of its instances: data, not `Module#refine`.
        def record_class_literal(node) = (@class_literals ||= Set.new) << node.location.start_offset

        def walk_children(node, prefix, body, in_def, owner, class_self)
          return if node.nil?

          node.rigor_each_child { |child| walk(child, prefix, body, in_def, owner, class_self) }
        end

        # Issue #1689 — `Class.new do … end` (or `Struct.new` / `Data.define` with a block), named or not: the block's
        # `self` is the class the call creates, so a `refine` directly in it is not `Module#refine`. The call's other
        # parts walk as they would anyway.
        def walked_class_new_call?(node, prefix, body, in_def, owner, class_self)
          block = node.block
          return false unless block.is_a?(Prism::BlockNode) && ScopeIndexer.meta_new_constant_rvalue?(node)
          return false if ScopeIndexer.module_new_call?(node)

          walk(node.receiver, prefix, body, in_def, owner, class_self) if node.receiver
          walk_children(node.arguments, prefix, body, in_def, owner, class_self)
          walk_children(block, prefix, body, in_def, nil, true)
          true
        end

        # `M = Module.new do … end`: the block's `self` is the module the write names, so a `refine` in it refines
        # for `M`. The write's other parts walk as they would anyway.
        def walked_meta_new_write?(node, prefix, body, in_def, owner, class_self)
          call = ScopeIndexer.meta_new_block_call(node)
          return false if call.nil? || !ScopeIndexer.module_new_call?(call)

          named = meta_new_owner(node, prefix)
          walk(call.receiver, prefix, body, in_def, owner, class_self) if call.receiver
          walk_children(call.arguments, prefix, body, in_def, owner, class_self)
          record_call(call, prefix, body, in_def, owner, class_self)
          walk_children(call.block, prefix, body, in_def, named, false)
          true
        end

        def meta_new_owner(node, prefix)
          case node
          when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode then (prefix + [node.name.to_s]).join("::")
          else Source::ConstantPath.declaration_prefix(prefix, node.target)&.join("::")
          end
        end

        def record_call(node, prefix, body, in_def, owner, class_self)
          record_class_string_literals(node) if class_self == true
          if class_self && ScopeIndexer.refine_call?(node)
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

        def record_class_string_literals(node)
          return unless RefineCensus.string_literal_call?(node)

          node.arguments&.arguments&.each do |argument|
            record_class_literal(argument) if RefineCensus.refine_string?(argument)
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
