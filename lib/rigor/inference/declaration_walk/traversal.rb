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
        EVENTS = %i[on_declaration on_def on_call on_constant_write].freeze

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

      NO_COLLECTORS = [].freeze
      private_constant :NO_COLLECTORS

      module_function

      # Walks `root` once for every collector, from `context` (a file's top level by default).
      def run(root, collectors, context = Context.root)
        Traversal.for(collectors).walk(root, collectors, context)
        collectors
      end

      # One run's dispatch: which events any collector overrides, so an event none of them handles costs no
      # call per node.
      class Traversal
        # The traversal for `collectors`. A single-collector run's depends on the collector's class alone, so
        # the main Ractor builds it once per class (the #1055 pattern in `FactStore::Target.local`); every
        # other run builds its own.
        def self.for(collectors)
          return new(collectors) unless collectors.size == 1 && Ractor.main?

          @single_runs[collectors.first.class] ||= new(collectors)
        end
        @single_runs = {}.compare_by_identity

        def initialize(collectors)
          @declarations = handles?(collectors, :on_declaration)
          @defs = handles?(collectors, :on_def)
          @calls = handles?(collectors, :on_call)
          @constant_writes = handles?(collectors, :on_constant_write)
          collectors.each { |collector| Collector.check_variants!(collector.class) }
          @ordinary_factories = collectors.any? { |collector| ordinary_factory?(collector) }
          @unnamed_factories = !collectors.all? { |collector| ordinary_factory?(collector) }
          @unrendered_variants = collectors.any? { |collector| variant(collector, :unrendered_header) != :children }
          @nesting_heads = collectors.any? { |collector| variant(collector, :lexical_prefix) == :nesting_head }
          # Only a multi-collector run keeps its collectors, which a cached single-collector traversal must
          # not hold on to, and the subsets it builds from them as it first needs each ({#subset}).
          if collectors.size > 1
            @run = collectors
            @subsets = {}
          end
          freeze
        end

        def walk(node, collectors, context) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          return unless node.is_a?(Prism::Node)

          # The arms are disjoint node classes, so their order is only a cost: the commonest kind is tried first.
          case node
          when Prism::CallNode
            collectors = descending(collectors) { |c| c.on_call(node, context) } if @calls
            return if collectors.empty?
            # Both block arms need a literal block, which most calls lack.
            return if node.block.is_a?(Prism::BlockNode) &&
                      (walk_factory_call?(node, collectors, context) || walk_eval_call?(node, collectors, context))
          when Prism::DefNode
            collectors = descending(collectors) { |c| c.on_def(node, context) } if @defs
            return if collectors.empty?
          when Prism::ClassNode, Prism::ModuleNode
            return if walk_declaration?(node, collectors, context)
          when Prism::SingletonClassNode
            return walk_singleton_class(node, collectors, context)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
               Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode
            collectors = descending(collectors) { |c| c.on_constant_write(node, context) } if @constant_writes
            return if collectors.empty? || walk_meta_new_write?(node, collectors, context)
          end

          node.rigor_each_child { |child| walk(child, collectors, context) }
        end

        private

        def handles?(collectors, event)
          collectors.any? { |collector| Collector.events_of(collector.class).include?(event) }
        end

        # A subset of a multi-collector run that its nodes keep asking for, built the first time and reused:
        # each collector alone (a pair in which one declines), the run without each collector (a larger run in
        # which one declines), and the run split by `factory_block` and `lexical_prefix` variant where it mixes
        # them. `key` is a Symbol for a split, or `[kind, collector]` for the other two.
        def subset(kind, collector = nil)
          table = (@subsets[kind] ||= {}.compare_by_identity)
          key = collector || kind
          table.fetch(key) { table[key] = yield.freeze }
        end

        def alone(collector)
          subset(:alone, collector) { [collector] }
        end

        def variant_split(rule, &)
          subset(rule) do
            second, first = @run.partition(&)
            [first.freeze, second.freeze]
          end
        end

        def variant(collector, rule)
          Collector.variant_of(collector.class, rule)
        end

        def ordinary_factory?(collector)
          variant(collector, :factory_block) == :ordinary_call
        end

        # The collectors that let the walk into the node the block asks each of them about. Every collector is
        # asked, in order, whatever the others answer. A run allocates nothing where at most one collector
        # declines; where two or more of a run of three or more decline, one Array.
        def descending(collectors, &)
          case collectors.size
          when 0 then collectors
          when 1 then yield(collectors.first) == DECLINE ? NO_COLLECTORS : collectors
          when 2 then descending_pair(collectors, yield(collectors.first), yield(collectors.last))
          else descending_many(collectors, &)
          end
        end

        def descending_many(collectors)
          declined = nil
          kept = nil
          collectors.each_with_index do |collector, index|
            if yield(collector) != DECLINE
              kept&.push(collector)
            elsif declined.nil? && kept.nil?
              declined = index
            else
              kept ||= collectors.take(index).tap { |list| list.delete_at(declined) }
            end
          end
          kept || (declined.nil? ? collectors : without(collectors, declined))
        end

        def without(collectors, index)
          declined = collectors[index]
          if collectors.equal?(@run)
            return subset(:without, declined) { @run.reject { |collector| collector.equal?(declined) } }
          end

          collectors.dup.tap { |list| list.delete_at(index) }
        end

        def descending_pair(collectors, first, last)
          if first == DECLINE
            last == DECLINE ? NO_COLLECTORS : alone(collectors.last)
          else
            last == DECLINE ? alone(collectors.first) : collectors
          end
        end

        # False only for a header that renders no prefix while every collector here follows the walk's
        # `unrendered_header` rule, which then walks the node's children like any node's.
        def walk_declaration?(node, collectors, context)
          body_context = context.declaration_body(node)
          return walk_unrendered_header?(node, collectors, context) if body_context.nil?

          collectors = descending(collectors) { |c| c.on_declaration(node, context, body_context) } if @declarations
          body = node.body
          walk(body, collectors, body_context) if body && !collectors.empty?
          true
        end

        # The `unrendered_header` rule: `:children` collectors walk every child under the enclosing context,
        # `:body_with_lost_nesting` ones the body alone under {Context#lost_header_body}, `:skip` ones nothing.
        def walk_unrendered_header?(node, collectors, context)
          return false unless @unrendered_variants

          children = collectors.select { |collector| variant(collector, :unrendered_header) == :children }
          node.rigor_each_child { |child| walk(child, children, context) } unless children.empty?
          lost = collectors.select { |collector| variant(collector, :unrendered_header) == :body_with_lost_nesting }
          walk(node.body, lost, context.lost_header_body) if node.body && !lost.empty?
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
          walk_rebound_body(node, body, collectors, context, body_self, :meta_new) if body
          true
        end

        # A meta-new or eval-family body, with `self` rebound to `owner`. The `lexical_prefix` rule decides
        # `owner`, so where the run mixes its variants the `:nesting_head` collectors take the owner their
        # prefix gives, and the body is walked once per distinct owner — once in all where the two agree.
        def walk_rebound_body(node, body, collectors, context, owner, kind)
          return walk(body, collectors, rebound(context, owner, kind)) unless @nesting_heads

          prefixes, heads = prefix_groups(collectors)
          head_owner = heads.empty? ? owner : split(node, context, kind, :nesting_head)[2]
          if head_owner == owner
            walk(body, collectors, rebound(context, owner, kind))
          else
            walk(body, prefixes, rebound(context, owner, kind)) unless prefixes.empty?
            walk(body, heads, rebound(context, head_owner, kind))
          end
        end

        def rebound(context, owner, kind)
          kind == :eval ? context.eval_body(owner) : context.meta_new_body(owner)
        end

        def split(node, context, kind, lexical_variant)
          kind == :eval ? context.eval_split(node, lexical_variant) : context.meta_new_split(node, lexical_variant)
        end

        # `[prefix, nesting_head]` collectors of a run that mixes the `lexical_prefix` variants.
        def prefix_groups(collectors)
          if collectors.equal?(@run)
            return variant_split(:lexical_prefix) { |collector| variant(collector, :lexical_prefix) == :nesting_head }
          end

          heads, prefixes = collectors.partition { |collector| variant(collector, :lexical_prefix) == :nesting_head }
          [prefixes, heads]
        end

        # The `factory_block` rule, for a call with a literal block. False when every collector here follows
        # `:ordinary_call`, so the call walks its children like any call. Otherwise the receiver and arguments
        # are walked once, for every collector, since both variants walk them under the enclosing context;
        # the variants part only at the block: the `:unnamed_self` collectors walk its body with an unnamed
        # `self`, the `:ordinary_call` ones the whole block, parameters included, under the enclosing context.
        # Each collector sees the same events in the same order as in a run of its own.
        def walk_factory_call?(node, collectors, context)
          return false unless @unnamed_factories && ScopeIndexer.meta_new_constant_rvalue?(node)

          unnamed = unnamed_factory_group(collectors)
          return false if unnamed.empty?

          walk(node.receiver, collectors, context)
          node.arguments&.arguments&.each { |argument| walk(argument, collectors, context) }
          block = node.block
          walk(block.body, unnamed, context.factory_body) if block.body
          walk(block, ordinary_factory_group(collectors), context) if unnamed.size < collectors.size
          true
        end

        def unnamed_factory_group(collectors)
          return collectors unless @ordinary_factories
          return factory_split.first if collectors.equal?(@run)

          collectors.reject { |collector| ordinary_factory?(collector) }
        end

        def ordinary_factory_group(collectors)
          return factory_split.last if collectors.equal?(@run)

          collectors.select { |collector| ordinary_factory?(collector) }
        end

        # `[unnamed_self, ordinary_call]` collectors of the whole run.
        def factory_split
          variant_split(:factory_block) { |collector| ordinary_factory?(collector) }
        end

        def walk_eval_call?(node, collectors, context)
          enclosing, body, eval_self = context.eval_split(node)
          return false if enclosing.nil?

          enclosing.each { |part| walk(part, collectors, context) }
          walk_rebound_body(node, body, collectors, context, eval_self, :eval) if body
          true
        end
      end
    end
  end
end
