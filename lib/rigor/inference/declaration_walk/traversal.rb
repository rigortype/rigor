# frozen_string_literal: true

require "prism"

require_relative "../../source/node_children"
require_relative "context"
require_relative "errors"
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
    #   header's constant path and superclass expression are not walked. A header that renders no name raises
    #   no event and follows the `unrendered_header` rule (below).
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
    #   children. A collector following the `:ordinary_call` variant of the `factory_block` rule (below) sees
    #   a bare factory block walked as any other call instead.
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
    # ## Variants
    #
    # Where the legacy walkers disagree on a context rule, a port keeps its walker's answer by naming a
    # variant of the rule in its class's `VARIANTS` (ADR-116 WD5; {RULE_VARIANTS} lists them). Collectors on
    # different variants of a rule still share a run: where the variants give a subtree different contexts
    # (a bare factory block, a meta-new or eval-family body, a header that renders no name) the walk goes down
    # once per variant in use, each collector only in its own, and once for all of them everywhere else. A
    # variant is a legacy answer kept on purpose, and #1521 tracks converging each one.
    #
    # The rule walk stays separate (ADR-53 rejected folding rule collectors into indexing): this walk only
    # builds discovery tables.
    module DeclarationWalk
      # A handler's answers: go on into the node, or leave its subtree to the run's other collectors.
      DESCEND = :descend
      DECLINE = :decline

      # Each context rule a collector may follow a legacy variant of, with its variants. The first is the
      # walk's own rule, which a collector follows unless its `VARIANTS` names another.
      #
      # - `factory_block` — a bare `Class.new { … }` / `Module.new` / `Struct.new` / `Data.define` block.
      #   `:unnamed_self` walks the factory's receiver and arguments, then the body with an unnamed `self`,
      #   and skips the block's parameters (`walk_class_cvars`' rule). `:ordinary_call` walks the call's
      #   children like any call's — receiver, arguments, the block's parameters and body — under the
      #   enclosing context, so a `self::` header in the body anchors on the enclosing self
      #   (`walk_class_superclasses`' rule; `class C; Class.new { class self::E < S; end }; end` files
      #   `C::E`, a class Ruby never creates; #1521 item 8).
      # - `anonymous_class_path` — the file path an anonymous class's synthetic name carries; answered by
      #   {Context#anonymous_class_path}, which documents `:whole_file` and `:outside_class_bodies` (#1521
      #   item 11).
      # - `unrendered_header` — a `class` / `module` whose header renders no name, which only a parse error
      #   produces (`class foo`, a `module` keyword followed by a `def`). `:children` walks every child, the
      #   header's parts included, under the enclosing context (`walk_class_superclasses`' rule).
      #   `:skip` walks nothing below it (the member-layout walkers'). `:body_with_lost_nesting` walks the body
      #   alone under {Context#lost_header_body} (`walk_def_nestings`'). #1521 item 3.
      # - `lexical_prefix` — the prefix meta-new and eval-family splits resolve against, answered by
      #   {Context#lexical_prefix}: `:prefix` or `walk_def_nestings`' `:nesting_head` (#1521 item 1).
      RULE_VARIANTS = {
        factory_block: %i[unnamed_self ordinary_call].freeze,
        anonymous_class_path: %i[whole_file outside_class_bodies].freeze,
        unrendered_header: %i[children skip body_with_lost_nesting].freeze,
        lexical_prefix: %i[prefix nesting_head].freeze
      }.freeze

      # The event handlers a collector may override; each answers {DESCEND} until overridden.
      module Collector
        EVENTS = %i[on_declaration on_def on_call on_constant_write on_sequence on_statement on_sequence_end].freeze

        # The statement-sequence events: a collector overriding any of them is handed all three.
        SEQUENCE_EVENTS = %i[on_sequence on_statement on_sequence_end].freeze

        # The legacy variants of {RULE_VARIANTS} this collector follows, `rule => variant`. A collector
        # overrides the constant, documenting each entry where it declares it.
        VARIANTS = {}.freeze

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

        # PROTOTYPE (ADR-116 WD5 amendment draft) — a statement list (`Prism::StatementsNode`), before its first
        # statement. `body` is the declaration-like body the list belongs to — a `class` / `module`,
        # `class <<`, meta-new, eval-family or bare-factory body, as the node the walk entered it by (the list
        # itself, or a body-level `begin`) — when the list is that body's or one of its body-level `begin`
        # clauses'; nil for any other list. {DECLINE} skips the list, and its end, for this collector.
        def on_sequence(_node, _context, _body)
          DESCEND
        end

        # Each direct statement of a list the collector descended into, in order, before the walk enters it.
        def on_statement(_node, _context)
          DESCEND
        end

        # After a list's last statement, for each collector that descended into the list. The answer is ignored.
        def on_sequence_end(_node, _context)
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

        # The variant of `rule` `klass` follows: its `VARIANTS` entry, or the walk's own rule.
        def self.variant_of(klass, rule)
          klass::VARIANTS.fetch(rule) { RULE_VARIANTS.fetch(rule).first }
        end

        # Raises {UnknownVariant} unless every `VARIANTS` entry of `klass` names a rule and one of its
        # variants, so a misspelt variant is a {ContractError} rather than the walk's rule followed silently:
        # an error row on the file in a file's own index, and an aborted run in the project pre-pass.
        def self.check_variants!(klass)
          klass::VARIANTS.each do |rule, variant|
            next if RULE_VARIANTS.fetch(rule, EMPTY).include?(variant)

            raise UnknownVariant, "#{klass}: no #{rule.inspect} variant #{variant.inspect} (ADR-116 WD5)"
          end
        end
        EMPTY = [].freeze
        private_constant :EMPTY
      end

      module_function

      # Walks `root` once for every collector, from `context` (a file's top level by default).
      def run(root, collectors, context = Context.root)
        traversal = Traversal.for(collectors)
        traversal.walk(root, collectors, traversal.all, context)
        collectors
      end

      # One run shape's dispatch. PROTOTYPE (ADR-116 WD5 amendment draft): the collectors live at a node are a
      # bitmask over the run's positions, not an Array. Asking, declining and forking are Integer operations,
      # so no descent allocates; an event is dispatched only where a collector that takes it is still live, so
      # a collector that declines a subtree costs nothing inside it; and the traversal depends on the run's
      # collector CLASSES alone, so the main Ractor builds it once per run shape and every file reuses it.
      class Traversal
        # Positions a mask can name. A run shape is a handful of collectors; the bound only keeps every mask a
        # fixnum.
        MAX_COLLECTORS = 60

        # The traversal for `collectors`' classes, in order. The main Ractor keeps one per run shape, found
        # through one identity table per position so that looking it up allocates nothing; a pool worker on
        # the Ractor backend builds its own (the #1055 pattern in `FactStore::Target.local`).
        def self.for(collectors)
          return new(collectors.map(&:class)) unless Ractor.main?

          table = @shapes
          index = 0
          while index < collectors.size
            table = (table[collectors[index].class] ||= {}.compare_by_identity)
            index += 1
          end
          table[:traversal] ||= new(collectors.map(&:class))
        end
        @shapes = {}.compare_by_identity

        # Every position of the run.
        attr_reader :all

        def initialize(classes)
          raise ArgumentError, "a run holds at most #{MAX_COLLECTORS} collectors" if classes.size > MAX_COLLECTORS

          classes.each { |klass| Collector.check_variants!(klass) }
          @all = (1 << classes.size) - 1
          take_events(classes)
          take_variants(classes)
          freeze
        end

        def walk(node, run, live, context) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          return unless node.is_a?(Prism::Node)

          # The arms are disjoint node classes, so their order is only a cost: the commonest kind is tried first.
          case node
          when Prism::CallNode
            live = descending(run, live, @calls) { |c| c.on_call(node, context) }
            return if live.zero?
            # Both block arms need a literal block, which most calls lack.
            return if node.block.is_a?(Prism::BlockNode) &&
                      (walk_factory_call?(node, run, live, context) || walk_eval_call?(node, run, live, context))
          when Prism::DefNode
            live = descending(run, live, @defs) { |c| c.on_def(node, context) }
            return if live.zero?
          when Prism::ClassNode, Prism::ModuleNode
            return if walk_declaration?(node, run, live, context)
          when Prism::SingletonClassNode
            return walk_singleton_class(node, run, live, context)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
               Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode
            live = descending(run, live, @constant_writes) { |c| c.on_constant_write(node, context) }
            return if live.zero? || walk_meta_new_write?(node, run, live, context)
          end
          if live.anybits?(@sequences) && node.is_a?(Prism::StatementsNode)
            return walk_sequence(node, run, live, context, nil)
          end

          node.rigor_each_child { |child| walk(child, run, live, context) }
        end

        private

        # The positions that take each event.
        def take_events(classes)
          @declarations = positions(classes) { |klass| handles?(klass, :on_declaration) }
          @defs = positions(classes) { |klass| handles?(klass, :on_def) }
          @calls = positions(classes) { |klass| handles?(klass, :on_call) }
          @constant_writes = positions(classes) { |klass| handles?(klass, :on_constant_write) }
          @sequences = positions(classes) { |klass| Collector::SEQUENCE_EVENTS.any? { |event| handles?(klass, event) } }
        end

        # The positions that follow each variant a fork depends on.
        def take_variants(classes)
          @ordinary_factories = positions(classes) { |klass| variant(klass, :factory_block) == :ordinary_call }
          @unrendered_children = positions(classes) { |klass| variant(klass, :unrendered_header) == :children }
          @unrendered_lost = positions(classes) do |klass|
            variant(klass, :unrendered_header) == :body_with_lost_nesting
          end
          @nesting_heads = positions(classes) { |klass| variant(klass, :lexical_prefix) == :nesting_head }
        end

        def positions(classes)
          mask = 0
          classes.each_with_index { |klass, index| mask |= (1 << index) if yield(klass) }
          mask
        end

        def handles?(klass, event)
          Collector.events_of(klass).include?(event)
        end

        def variant(klass, rule)
          Collector.variant_of(klass, rule)
        end

        # `live` without the collectors the block declines for. Only the live collectors that take the event
        # (`takers`) are asked, in run order: a collector that does not override it would answer {DESCEND}.
        # Every operation is on fixnums, so asking allocates nothing whatever the answers.
        def descending(run, live, takers)
          asked = live & takers
          until asked.zero?
            lowest = asked & -asked
            live &= ~lowest if yield(run[lowest.bit_length - 1]) == DECLINE
            asked ^= lowest
          end
          live
        end

        # A declaration-like body. Only where a sequence collector is live is it walked differently, and then
        # only in the events it adds: the children are walked in the order `rigor_each_child` gives them.
        def walk_body(body, run, live, context)
          return walk(body, run, live, context) unless live.anybits?(@sequences)

          case body
          when Prism::StatementsNode then walk_sequence(body, run, live, context, body)
          when Prism::BeginNode then walk_begin_body(body, run, live, context)
          else walk(body, run, live, context)
          end
        end

        # A body-level `begin`: its statements, rescue clauses, `else` and `ensure`, in child order, with each
        # clause's statement list handed to the sequence events as part of the body.
        def walk_begin_body(body, run, live, context)
          walk_sequence(body.statements, run, live, context, body) if body.statements
          clause = body.rescue_clause
          while clause
            exceptions = clause.exceptions
            index = 0
            while index < exceptions.size
              walk(exceptions[index], run, live, context)
              index += 1
            end
            walk(clause.reference, run, live, context) if clause.reference
            walk_sequence(clause.statements, run, live, context, body) if clause.statements
            clause = clause.subsequent
          end
          walk_sequence(body.else_clause.statements, run, live, context, body) if body.else_clause&.statements
          walk_sequence(body.ensure_clause.statements, run, live, context, body) if body.ensure_clause&.statements
        end

        def walk_sequence(node, run, live, context, body)
          live = descending(run, live, @sequences) { |c| c.on_sequence(node, context, body) }
          return if live.zero?

          statements = node.body
          index = 0
          while index < statements.size
            statement = statements[index]
            walk(statement, run, descending(run, live, @sequences) { |c| c.on_statement(statement, context) }, context)
            index += 1
          end
          ending = live & @sequences
          until ending.zero?
            lowest = ending & -ending
            run[lowest.bit_length - 1].on_sequence_end(node, context)
            ending ^= lowest
          end
        end

        # False only for a header that renders no prefix while every live collector follows the walk's
        # `unrendered_header` rule, which then walks the node's children like any node's.
        def walk_declaration?(node, run, live, context)
          body_context = context.declaration_body(node)
          return walk_unrendered_header?(node, run, live, context) if body_context.nil?

          live = descending(run, live, @declarations) { |c| c.on_declaration(node, context, body_context) }
          body = node.body
          walk_body(body, run, live, body_context) if body && !live.zero?
          true
        end

        # The `unrendered_header` rule: `:children` collectors walk every child under the enclosing context,
        # `:body_with_lost_nesting` ones the body alone under {Context#lost_header_body}, `:skip` ones nothing.
        def walk_unrendered_header?(node, run, live, context)
          children = live & @unrendered_children
          return false if children == live

          node.rigor_each_child { |child| walk(child, run, children, context) } unless children.zero?
          lost = live & @unrendered_lost
          walk_body(node.body, run, lost, context.lost_header_body) if node.body && !lost.zero?
          true
        end

        def walk_singleton_class(node, run, live, context)
          walk(node.expression, run, live, context)
          body = node.body
          walk_body(body, run, live, context.singleton_class_body) if body
        end

        def walk_meta_new_write?(node, run, live, context)
          enclosing, body, body_self = context.meta_new_split(node)
          return false if enclosing.nil?

          enclosing.each { |part| walk(part, run, live, context) }
          walk_rebound_body(node, body, run, live, context, body_self, :meta_new) if body
          true
        end

        # A meta-new or eval-family body, with `self` rebound to `owner`. The `lexical_prefix` rule decides
        # `owner`, so where the live collectors mix its variants the `:nesting_head` ones take the owner their
        # prefix gives, and the body is walked once per distinct owner — once in all where the two agree.
        def walk_rebound_body(node, body, run, live, context, owner, kind)
          heads = live & @nesting_heads
          return walk_body(body, run, live, rebound(context, owner, kind)) if heads.zero?

          head_owner = split(node, context, kind, :nesting_head)[2]
          if head_owner == owner
            walk_body(body, run, live, rebound(context, owner, kind))
          else
            prefixes = live & ~@nesting_heads
            walk_body(body, run, prefixes, rebound(context, owner, kind)) unless prefixes.zero?
            walk_body(body, run, heads, rebound(context, head_owner, kind))
          end
        end

        def rebound(context, owner, kind)
          kind == :eval ? context.eval_body(owner) : context.meta_new_body(owner)
        end

        def split(node, context, kind, lexical_variant)
          kind == :eval ? context.eval_split(node, lexical_variant) : context.meta_new_split(node, lexical_variant)
        end

        # The `factory_block` rule, for a call with a literal block. False when every live collector follows
        # `:ordinary_call`, so the call walks its children like any call. Otherwise the receiver and arguments
        # are walked once, for every live collector, since both variants walk them under the enclosing context;
        # the variants part only at the block: the `:unnamed_self` collectors walk its body with an unnamed
        # `self`, the `:ordinary_call` ones the whole block, parameters included, under the enclosing context.
        # Each collector sees the same events in the same order as in a run of its own.
        def walk_factory_call?(node, run, live, context)
          unnamed = live & ~@ordinary_factories
          return false if unnamed.zero? || !ScopeIndexer.meta_new_constant_rvalue?(node)

          walk(node.receiver, run, live, context)
          node.arguments&.arguments&.each { |argument| walk(argument, run, live, context) }
          block = node.block
          walk_body(block.body, run, unnamed, context.factory_body) if block.body
          ordinary = live & @ordinary_factories
          walk(block, run, ordinary, context) unless ordinary.zero?
          true
        end

        def walk_eval_call?(node, run, live, context)
          enclosing, body, eval_self = context.eval_split(node)
          return false if enclosing.nil?

          enclosing.each { |part| walk(part, run, live, context) }
          walk_rebound_body(node, body, run, live, context, eval_self, :eval) if body
          true
        end
      end
    end
  end
end
