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
    # raises; a clause enters with each such name rebound to `Dynamic[top]` instead ({.widen}).
    module ClauseWidening
      WRITE_NODES = Set[
        *CapturedLocals::LOCAL_WRITE_NODES,
        Prism::InstanceVariableWriteNode,
        Prism::InstanceVariableOperatorWriteNode,
        Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode,
        Prism::InstanceVariableTargetNode
      ].freeze

      SCOPE_BODY_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
      private_constant :SCOPE_BODY_NODES

      module_function

      # The local and instance variable names `sources` write, a nested block's included (it may write an outer
      # local), or nil for none. A `def` or class body writes nothing here.
      def writes(sources)
        found = nil
        sources.each { |source| found = collect(source, found) if source }
        found
      end

      # `scope` with each name of `names` that it binds rebound to `Dynamic[top]`, or nil when none changes.
      def widen(scope, names)
        return nil if names.nil?

        untyped = Type::Combinator.untyped
        widened = names.reduce(scope) do |acc, name|
          ivar = name.start_with?("@")
          current = ivar ? scope.ivar(name) : scope.local(name)
          next acc if current.nil? || current == untyped

          ivar ? acc.with_ivar(name, untyped).without_ivar_guard(name) : acc.with_local(name, untyped)
        end
        widened.equal?(scope) ? nil : widened
      end

      def collect(node, found)
        return found if SCOPE_BODY_NODES.any? { |klass| node.is_a?(klass) }

        (found ||= Set.new) << node.name if WRITE_NODES.include?(node.class)
        node.rigor_each_child { |child| found = collect(child, found) }
        found
      end
      private_class_method :collect
    end
  end
end
