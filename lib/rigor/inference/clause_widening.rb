# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"
require_relative "../type"
require_relative "captured_locals"

module Rigor
  module Inference
    # Issues #1231 and #1839 — a rescue clause runs after the `begin` body raised from any point in it, and an `ensure`
    # clause after the body, its `else` or a rescue clause raised, so each local or instance variable those wrote may
    # hold any value one of their writes gave it, or the one it entered with. The engine does not track where the body
    # raises; a clause enters with such a name rebound to `Dynamic[top]` instead ({.widen}).
    #
    # Not every name the body writes: one the clause mentions, whose binding the clause reads, and one the body
    # writes more than once or inside a block or loop, which can hold a value neither the entry nor the body's exit
    # binds. A name written once and never mentioned leaves the clause at its entry binding, which the join past the
    # `begin` already pairs with the body's exit binding, the value of that one write.
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

      # A write under one of these may run more than once.
      REPEATING_NODES = [
        Prism::BlockNode, Prism::LambdaNode, Prism::WhileNode, Prism::UntilNode, Prism::ForNode
      ].freeze

      SCOPE_BODY_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze

      # The names `sources` write: `names` all of them, `repeated` those written more than once or inside a block or
      # loop, a nested block's included (it may write an outer local). A `def` or class body writes nothing here.
      Writes = Data.define(:names, :repeated)

      module_function

      # The {Writes} of `sources`, or nil for none.
      def writes(sources)
        counts = nil
        sources.each { |source| counts = count_writes(source, counts, false) if source }
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
          next acc if current.nil? || current == untyped

          ivar ? acc.with_ivar(name, untyped).without_ivar_guard(name) : acc.with_local(name, untyped)
        end
        widened.equal?(scope) ? nil : widened
      end

      # `counts` with each write under `node` counted, one under a repeating node counted twice.
      def count_writes(node, counts, repeating)
        return counts if SCOPE_BODY_NODES.any? { |klass| node.is_a?(klass) }

        if WRITE_NODES.include?(node.class)
          counts ||= Hash.new(0)
          counts[node.name] += repeating ? 2 : 1
        end
        repeating ||= REPEATING_NODES.any? { |klass| node.is_a?(klass) }
        node.rigor_each_child { |child| counts = count_writes(child, counts, repeating) }
        counts
      end

      # `found` with each name of `among` that `node` mentions added.
      def mentions(node, among, found)
        return found if node.nil? || SCOPE_BODY_NODES.any? { |klass| node.is_a?(klass) }

        found << node.name if MENTION_NODES.include?(node.class) && among.include?(node.name)
        node.rigor_each_child { |child| found = mentions(child, among, found) }
        found
      end
      private_class_method :count_writes, :mentions
    end
  end
end
