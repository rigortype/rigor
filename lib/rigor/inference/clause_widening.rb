# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"
require_relative "../type"
require_relative "alias_mutation_floor"
require_relative "captured_locals"
require_relative "opaque_mutation"
require_relative "unknown_store_widening"

module Rigor
  module Inference
    # Issues #1231 and #1839 — a rescue clause runs after the `begin` body raised from any point in it, and an `ensure`
    # clause after the body, its `else` or a rescue clause raised, so each local or instance variable those wrote may
    # hold any value one of their writes gave it, or the one it entered with. The engine does not track where the body
    # raises; a clause enters with such a name rebound to `Dynamic[top]` instead ({.widen}).
    #
    # Not every name the body writes: one the clause mentions, whose binding the clause reads, and one the body
    # writes more than once, which can hold a value neither the entry nor the body's exit binds. A name written once
    # and never mentioned leaves the clause at its entry binding, which the join past the `begin` already pairs with
    # the body's exit binding, the value of that one write (a write in a block or loop body included: the scope a
    # block call or loop leaves joins every iteration's).
    module ClauseWidening
      WRITE_NODES = Set[
        *CapturedLocals::LOCAL_WRITE_NODES,
        Prism::InstanceVariableWriteNode,
        Prism::InstanceVariableOperatorWriteNode,
        Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode,
        Prism::InstanceVariableTargetNode
      ].freeze

      MENTION_NODES = Set[Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode, *WRITE_NODES].freeze

      SCOPE_BODY_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze

      # The names `sources` write: `names` all of them, `repeated` those written more than once, a nested block's
      # included (it may write an outer local). A `def` or class body writes nothing here.
      Writes = Data.define(:names, :repeated)

      module_function

      # The {Writes} of `sources`, or nil for none.
      def writes(sources)
        counts = nil
        sources.each { |source| counts = count_writes(source, counts) if source }
        return nil if counts.nil?

        Writes.new(names: counts.keys.to_set, repeated: counts.filter_map { |name, count| name if count > 1 }.to_set)
      end

      # `scope` with each name of `writes` that `clause` mentions, or that is repeated, rebound to `Dynamic[top]` where
      # `scope` binds it, or nil when none changes. `clause` may be nil (an empty rescue clause).
      def widen(scope, writes, clause)
        return nil if writes.nil?

        names = mentions(clause, writes.names, writes.repeated.dup)
        untyped = Type::Combinator.untyped
        widened = names.reduce(scope) do |acc, name|
          ivar = name.start_with?("@")
          current = ivar ? scope.ivar(name) : scope.local(name)
          next acc if current.nil? || Type::Combinator.untyped?(current)

          ivar ? acc.with_ivar(name, untyped).without_ivar_guard(name) : acc.with_local(name, untyped)
        end
        widened.equal?(scope) ? nil : widened
      end

      # Issue #3340 — `scope`, the entry of `node`'s rescue chain, past what the `begin` body may have done to the
      # objects its locals hold: a clause runs after the body raised from any point, and an in-place mutation rebinds
      # nothing, so {.widen} does not see it. Each local the body mutates in place
      # (`CapturedLocals.loop_content_mutations`) reads what it can hold after any prefix of the body ran
      # ({.past_any_prefix}), and each local the body hands to unread code, or mutates through a literal `send`, a
      # `Method` object or a symbol block, takes one unknown store ({OpaqueMutation.floor_reached}). `scope` itself
      # for a `begin` with no rescue clause. A body that can mutate nothing `scope` binds
      # ({CapturedLocals.may_touch_capture?}, an allocation-free scan) skips the first half, and a scope that binds
      # no literal shape the second.
      def content_entry(scope, node)
        body = node.statements
        return scope unless node.rescue_clause && body

        if CapturedLocals.may_touch_capture?(body, scope)
          scope = CapturedLocals.loop_content_mutations(body, scope).reduce(scope) do |acc, (name, sites)|
            type = acc.local(name)
            type.nil? ? acc : acc.with_mutated_local(name, past_any_prefix(type, sites, body, name))
          end
        end
        return scope unless AliasMutationFloor.local_besides?(scope, nil) { |t| AliasMutationFloor.literal_shape?(t) }

        OpaqueMutation.floor_reached(body, scope)
      end

      # A closed hash shape the body does nothing to but remove from keeps its shape with every key optional
      # ({AliasMutationFloor.removed_keys_shape}): nothing was stored, and a read of a key the body may have deleted
      # still answers its `nil`, so `h.delete(k); raise` then `h[k].x` in the clause reports. That holds only where
      # the removers are everything the body does with the local ({.only_removed?}). Any other binding takes the
      # unknown store of every site, with the gradual arm where its contents stay value-pinned, as a loop body's
      # later pass enters (`StatementEvaluator#unknown_store_binding`).
      def past_any_prefix(type, sites, body, name)
        if type.is_a?(Type::HashShape) && only_removed?(body, name, sites)
          shape = AliasMutationFloor.removed_keys_shape(type, sites.first.name)
          return shape if shape
        end
        widened = UnknownStoreWidening.widen(type, sites)
        UnknownStoreWidening.value_pinned_collection?(widened) ? UnknownStoreWidening.gradual_content(widened) : widened
      end

      # True when every read of the local `name` under `body` is the receiver of one of `sites`, each a blockless
      # remover or reorderer called on the local itself. Any other mention may reach the object another way: a
      # `send`, a `yield`, an alias, an element read, a remover's own block (whose parameters are the values), an
      # argument. Then the body may have stored, and the shape's value pins do not stand.
      def only_removed?(body, name, sites)
        sites.all? { |site| own_remover?(site, name) } && mentions_of(body, name) == sites.size
      end

      def own_remover?(site, name)
        site.is_a?(Prism::CallNode) && UnknownStoreWidening::VALUE_PRESERVING.include?(site.name) &&
          site.block.nil? && site.receiver.is_a?(Prism::LocalVariableReadNode) && site.receiver.name == name
      end

      # How many times `node` reads or writes the local `name`, at any depth.
      def mentions_of(node, name)
        count = MENTION_NODES.include?(node.class) && node.name == name ? 1 : 0
        node.rigor_each_child { |child| count += mentions_of(child, name) }
        count
      end

      # `counts` with each write under `node` counted.
      def count_writes(node, counts)
        return counts if SCOPE_BODY_NODES.any? { |klass| node.is_a?(klass) }

        if WRITE_NODES.include?(node.class)
          counts ||= Hash.new(0)
          counts[node.name] += 1
        end
        node.rigor_each_child { |child| counts = count_writes(child, counts) }
        counts
      end

      # `found` with each name of `among` that `node` mentions added.
      def mentions(node, among, found)
        return found if node.nil? || SCOPE_BODY_NODES.any? { |klass| node.is_a?(klass) }

        found << node.name if MENTION_NODES.include?(node.class) && among.include?(node.name)
        node.rigor_each_child { |child| found = mentions(child, among, found) }
        found
      end
      private_class_method :count_writes, :mentions, :past_any_prefix, :only_removed?, :own_remover?, :mentions_of
    end
  end
end
