# frozen_string_literal: true

require "prism"

require_relative "../../source/node_children"
require_relative "context"
require_relative "shadow"

module Rigor
  module Inference
    # ADR-116 WD5 (ADR-53 Theme B): one traversal owns the declaration-context rules that `ScopeIndexer`'s table
    # walkers each copied — what `self`, the cref and `Module.nesting` become under `class`/`module`, `class <<`,
    # a `K = Class.new { … }`-family write, a bare factory block, and an eval-family block. A discovery table
    # becomes a collector that receives events and never tracks context itself; the {Context} it is handed is
    # the walk's.
    #
    # Require `rigor/inference/declaration_walk`, not this file: the rules the walk applies are `ScopeIndexer`
    # functions, and that entry point loads them.
    #
    # The arms, in the order the walk tries them:
    #
    # - `class` / `module` — {Collector#on_declaration}, then the body under {Context#declaration_body}. The
    #   header's constant path and superclass expression are not walked.
    # - `class << expr` — the expression under the enclosing context, the body under
    #   {Context#singleton_class_body}.
    # - a constant write (the four spellings that can name a class) — {Collector#on_constant_write}; then, when
    #   the rvalue is the meta-new idiom, ONLY the factory call's receiver and arguments, under the enclosing
    #   context, and its block body, rebound to the class the write names. Nothing else of the write is
    #   walked: not the target's parent (`P` in `P::K = …`), not the guard's read in `K = K || …`, not a
    #   `.freeze` tail's call, not the block's parameters, and the factory call itself raises no
    #   {Collector#on_call}. A write whose rvalue is not the idiom walks its children, as any node does.
    # - `def` — {Collector#on_def}, then the children.
    # - a call — {Collector#on_call}; then a bare factory block (`Class.new { … }`, `Module.new`, `Struct.new`,
    #   `Data.define`) walks its receiver and arguments under the enclosing context and its body with an
    #   unnamed `self`, and an eval-family block (`class_eval`, `module_eval`, `class_exec`, `module_exec`,
    #   `instance_eval`, `instance_exec`) its receiver and arguments under the enclosing context and its body
    #   with `self` rebound to the receiver. Neither walks the block's parameters. Any other call walks its
    #   children.
    #
    # Every other node walks its children under the context it was reached with, in `compact_child_nodes`
    # order, so a collector sees its events in the order the legacy walker it replaces accumulated them.
    #
    # ## The collector protocol
    #
    # A collector includes {Collector} and overrides the events it needs. Each handler answers {DESCEND} or
    # {DECLINE}: {DECLINE} takes the node's whole subtree away from THIS collector, while the other collectors
    # of the same run continue into it. Any other answer descends. The walk dispatches only the events some
    # collector of the run overrides.
    #
    # The rule walk stays separate (ADR-53 rejected folding rule collectors into indexing): this walk only
    # builds discovery tables.
    module DeclarationWalk
      # A handler's answers: go on into the node, or leave its subtree to the run's other collectors.
      DESCEND = :descend
      DECLINE = :decline

      # The event handlers a collector may override; each answers {DESCEND} until overridden.
      module Collector
        EVENTS = %i[on_declaration on_def on_call on_constant_write].freeze

        # A `class` / `module` header. `body` is the context its body is walked under; it exists even when
        # the declaration has no body.
        def on_declaration(_node, _context, _body)
          DESCEND
        end

        def on_def(_node, _context)
          DESCEND
        end

        # Every call, the factory and eval-family calls included, before the walk enters its block.
        def on_call(_node, _context)
          DESCEND
        end

        # `K = …`, `P::K = …`, `K ||= …` and `P::K ||= …`, before the walk decides whether the rvalue opens a
        # meta-new body.
        def on_constant_write(_node, _context)
          DESCEND
        end

        # The {EVENTS} `klass` overrides. Answered once per class: the table is a module ivar, which only the
        # main Ractor may touch, so a pool worker on the Ractor backend recomputes it instead (the #1055
        # pattern in `FactStore::Target.local`); the answer is the same either way.
        def self.events_of(klass)
          return overridden_events(klass) unless Ractor.main?

          @events_by_class[klass] ||= overridden_events(klass)
        end
        @events_by_class = {}.compare_by_identity

        def self.overridden_events(klass)
          EVENTS.reject { |event| klass.instance_method(event).owner.equal?(self) }.freeze
        end
        private_class_method :overridden_events
      end

      NO_COLLECTORS = [].freeze
      private_constant :NO_COLLECTORS

      module_function

      # Walks `root` once for every collector, from `context` (a file's top level by default).
      def run(root, collectors, context = Context.root)
        Traversal.new(collectors).walk(root, collectors, context)
        collectors
      end

      # One run's dispatch: which events any collector overrides, so an event none of them handles costs no
      # call per node.
      class Traversal
        def initialize(collectors)
          handled = collectors.map { |collector| Collector.events_of(collector.class) }
          @declarations = handled.any? { |events| events.include?(:on_declaration) }
          @defs = handled.any? { |events| events.include?(:on_def) }
          @calls = handled.any? { |events| events.include?(:on_call) }
          @constant_writes = handled.any? { |events| events.include?(:on_constant_write) }
          @alone = alone_table(collectors)
          freeze
        end

        def walk(node, collectors, context) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            return if walk_declaration?(node, collectors, context)
          when Prism::SingletonClassNode
            return walk_singleton_class(node, collectors, context)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
               Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode
            collectors = descending(collectors) { |c| c.on_constant_write(node, context) } if @constant_writes
            return if collectors.empty? || walk_meta_new_write?(node, collectors, context)
          when Prism::DefNode
            collectors = descending(collectors) { |c| c.on_def(node, context) } if @defs
            return if collectors.empty?
          when Prism::CallNode
            collectors = descending(collectors) { |c| c.on_call(node, context) } if @calls
            return if collectors.empty? || walk_factory_call?(node, collectors, context) ||
                      walk_eval_call?(node, collectors, context)
          end

          node.rigor_each_child { |child| walk(child, collectors, context) }
        end

        private

        # Each collector alone, for a two-collector run in which one of them declines a node; nil otherwise.
        def alone_table(collectors)
          return nil unless collectors.size == 2

          collectors.to_h { |collector| [collector, [collector].freeze] }.compare_by_identity
        end

        # The collectors that let the walk into the node the block asks each of them about. Every collector is
        # asked, in order, whatever the others answer. One or two collectors allocate nothing; a larger run
        # allocates one Array at a node some collector declines.
        def descending(collectors)
          case collectors.size
          when 0 then collectors
          when 1 then yield(collectors.first) == DECLINE ? NO_COLLECTORS : collectors
          when 2 then descending_pair(collectors, yield(collectors.first), yield(collectors.last))
          else
            kept = nil
            collectors.each_with_index do |collector, index|
              if yield(collector) == DECLINE
                kept ||= collectors.take(index)
              else
                kept&.push(collector)
              end
            end
            kept || collectors
          end
        end

        def descending_pair(collectors, first, last)
          if first == DECLINE
            last == DECLINE ? NO_COLLECTORS : @alone.fetch(collectors.last)
          else
            last == DECLINE ? @alone.fetch(collectors.first) : collectors
          end
        end

        # False only for a header that renders no prefix, which then walks its children like any node.
        def walk_declaration?(node, collectors, context)
          body_context = context.declaration_body(node)
          return false if body_context.nil?

          collectors = descending(collectors) { |c| c.on_declaration(node, context, body_context) } if @declarations
          body = node.body
          walk(body, collectors, body_context) if body && !collectors.empty?
          true
        end

        def walk_singleton_class(node, collectors, context)
          walk(node.expression, collectors, context)
          body = node.body
          walk(body, collectors, context.singleton_class_body) if body
        end

        def walk_meta_new_write?(node, collectors, context)
          enclosing, body, body_self = context.meta_new_split(node)
          return false if enclosing.nil?

          enclosing.each { |part| walk(part, collectors, context) }
          walk(body, collectors, context.rebound(body_self)) if body
          true
        end

        def walk_factory_call?(node, collectors, context)
          block = node.block
          return false unless block.is_a?(Prism::BlockNode) && ScopeIndexer.meta_new_constant_rvalue?(node)

          walk(node.receiver, collectors, context)
          node.arguments&.arguments&.each { |argument| walk(argument, collectors, context) }
          body = block.body
          walk(body, collectors, context.rebound(Context::EMPTY_PREFIX)) if body
          true
        end

        def walk_eval_call?(node, collectors, context)
          enclosing, body, eval_self = context.eval_split(node)
          return false if enclosing.nil?

          enclosing.each { |part| walk(part, collectors, context) }
          walk(body, collectors, context.rebound(eval_self)) if body
          true
        end
      end
    end
  end
end
