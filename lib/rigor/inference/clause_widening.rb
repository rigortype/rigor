# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"
require_relative "../type"
require_relative "alias_mutation_floor"
require_relative "captured_locals"
require_relative "element_read_widening"
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

      # Issue #3340 — `scope`, the entry of `node`'s rescue chain, with each local the `begin` body mutates in place
      # (`CapturedLocals.loop_content_mutations`) at what it can hold after any prefix of the body ran
      # ({.past_any_prefix}): a clause runs after the body raised from any point, and an in-place mutation rebinds
      # nothing, so {.widen} does not see it. `scope` itself for a `begin` with no rescue clause, and for a body
      # that can mutate nothing `scope` binds ({CapturedLocals.may_touch_capture?}, an allocation-free scan).
      def content_entry(scope, node)
        body = node.statements
        return scope unless node.rescue_clause && body && CapturedLocals.may_touch_capture?(body, scope)

        CapturedLocals.loop_content_mutations(body, scope).reduce(scope) do |acc, (name, sites)|
          type = acc.local(name)
          type.nil? ? acc : acc.with_mutated_local(name, past_any_prefix(type, sites))
        end
      end

      # A closed hash shape every site only removes from keeps its shape with every key optional
      # ({AliasMutationFloor.removed_keys_shape}): nothing was stored, and a read of a key the body may have deleted
      # still answers its `nil`, so `h.delete(k); raise` then `h[k].x` in the clause reports. Any other binding
      # takes the unknown store of every site, with the gradual arm where its contents stay value-pinned, as a loop
      # body's later pass enters (`StatementEvaluator#unknown_store_binding`).
      def past_any_prefix(type, sites)
        if type.is_a?(Type::HashShape) && sites.all? { |site| own_remover?(site) }
          shape = AliasMutationFloor.removed_keys_shape(type, sites.first.name)
          return shape if shape
        end
        widened = UnknownStoreWidening.widen(type, sites)
        UnknownStoreWidening.value_pinned_collection?(widened) ? UnknownStoreWidening.gradual_content(widened) : widened
      end

      # A remover or reorderer called on the binding itself, not on an element of it or through a callee.
      def own_remover?(site)
        site.is_a?(Prism::CallNode) && UnknownStoreWidening::VALUE_PRESERVING.include?(site.name) &&
          ElementReadWidening.element_read_path(site.receiver).nil?
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
      private_class_method :count_writes, :mentions, :past_any_prefix, :own_remover?
    end
  end
end
