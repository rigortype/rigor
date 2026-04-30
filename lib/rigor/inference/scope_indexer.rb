# frozen_string_literal: true

require "prism"

require_relative "../scope"
require_relative "../type"
require_relative "statement_evaluator"

module Rigor
  module Inference
    # Builds a per-node scope index for a Prism program by running
    # `Rigor::Inference::StatementEvaluator` over the root and recording
    # the entry scope visible at every node. Expression-interior nodes
    # the evaluator does not specialise (call receivers, arguments,
    # array/hash elements, ...) inherit their nearest statement-y
    # ancestor's recorded scope, so a downstream caller that looks up
    # the scope for any Prism node in the tree always gets the scope
    # that was effectively visible at that point.
    #
    # The CLI commands `rigor type-of` and `rigor type-scan` consume
    # the index so that local-variable bindings established earlier in
    # the program are visible to the typer when probing later nodes.
    # Without the index, both commands would type every node under an
    # empty scope and miss the constant-folding / dispatch precision
    # that Slice 3 phase 2's StatementEvaluator unlocks.
    #
    # The returned object is an identity-comparing Hash:
    #
    # ```ruby
    # index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Scope.empty)
    # index[some_prism_node] #=> the Rigor::Scope visible at that node
    # ```
    #
    # Nodes that are not part of the program subtree (e.g. synthesised
    # virtual nodes that the caller looks up after the fact) yield the
    # `default_scope`. The returned Hash is mutable in principle but
    # callers MUST treat it as read-only; the indexer itself never
    # exposes a way to update it past construction.
    module ScopeIndexer
      module_function

      # Build the scope index for a Prism program subtree.
      #
      # @param root [Prism::Node] usually a `Prism::ProgramNode`, but any
      #   subtree the caller wants the indexer to walk works.
      # @param default_scope [Rigor::Scope] the scope used for the root,
      #   and the fallback returned for any Prism node not contained in
      #   `root`'s subtree.
      # @return [Hash{Prism::Node => Rigor::Scope}] identity-comparing
      #   table whose default value is `default_scope`.
      def index(root, default_scope:)
        # Slice A-declarations. Build the declaration overrides
        # first so every scope handed to the StatementEvaluator
        # already carries the table; structural sharing through
        # `Scope#with_local` / `#with_fact` / `#with_self_type`
        # propagates it across every derived scope.
        declared_types = build_declaration_overrides(root)
        seeded_scope = default_scope.with_declared_types(declared_types)

        table = {}.compare_by_identity
        table.default = seeded_scope

        on_enter = ->(node, scope) { table[node] = scope unless table.key?(node) }
        StatementEvaluator.new(scope: seeded_scope, on_enter: on_enter).evaluate(root)

        propagate(root, table, seeded_scope)
        table
      end

      # Walks the program once for `Prism::ModuleNode` and
      # `Prism::ClassNode`, recording the `Singleton[<qualified>]`
      # type for the outermost `constant_path` node of each
      # declaration. Inner segments of a `class Foo::Bar::Baz`
      # path remain real references (resolved through the
      # ordinary lexical walk), so we annotate ONLY the topmost
      # path node. Nested declarations contribute their fully
      # qualified path: `class A::B; class C; ...` produces
      # `A::B` for the outer and `A::B::C` for the inner.
      def build_declaration_overrides(root)
        table = {}.compare_by_identity
        record_declarations(root, [], table)
        table.freeze
      end

      def record_declarations(node, qualified_prefix, table)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ModuleNode, Prism::ClassNode
          name = qualified_name_for(node.constant_path)
          if name
            full = (qualified_prefix + [name]).join("::")
            table[node.constant_path] = Type::Combinator.singleton_of(full)
            child_prefix = qualified_prefix + [name]
            record_declarations(node.body, child_prefix, table) if node.body
            return
          end
        end

        node.compact_child_nodes.each { |child| record_declarations(child, qualified_prefix, table) }
      end

      def qualified_name_for(constant_path_node)
        case constant_path_node
        when Prism::ConstantReadNode
          constant_path_node.name.to_s
        when Prism::ConstantPathNode
          render_constant_path(constant_path_node)
        end
      end

      def render_constant_path(node)
        prefix =
          case node.parent
          when Prism::ConstantReadNode then "#{node.parent.name}::"
          when Prism::ConstantPathNode then "#{render_constant_path(node.parent)}::"
          else ""
          end
        "#{prefix}#{node.name}"
      end

      # Walks `node`'s subtree DFS and fills in scope entries for every
      # Prism node the StatementEvaluator did not visit (i.e. expression-
      # interior nodes like the receiver/args of a CallNode). Those
      # nodes inherit their nearest recorded ancestor's scope.
      def propagate(node, table, parent_scope)
        return unless node.is_a?(Prism::Node)

        current_scope =
          if table.key?(node)
            table[node]
          else
            table[node] = parent_scope
            parent_scope
          end

        node.compact_child_nodes.each { |child| propagate(child, table, current_scope) }
      end
    end
  end
end
