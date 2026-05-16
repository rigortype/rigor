# frozen_string_literal: true

require "prism"

require_relative "uri"

module Rigor
  module LanguageServer
    # Answers `textDocument/documentSymbol` requests by walking the
    # Prism AST and emitting one LSP `DocumentSymbol` per
    # `ClassNode` / `ModuleNode` / `DefNode`. Nested classes /
    # modules / methods nest in the `children` array so the editor's
    # outline tree mirrors the source structure.
    #
    # SymbolKind mapping (LSP § "SymbolKind"):
    # - Class       (5)  — `class Foo`
    # - Module      (2)  — `module Foo`
    # - Method      (6)  — `def m` inside a class / module
    # - Function    (12) — `def m` at top-level (no enclosing class)
    class DocumentSymbolProvider
      KIND_MODULE   = 2
      KIND_CLASS    = 5
      KIND_METHOD   = 6
      KIND_FUNCTION = 12

      def initialize(buffer_table:, project_context:)
        @buffer_table = buffer_table
        @project_context = project_context
      end

      # @return [Array<Hash>, nil] LSP `DocumentSymbol[]` for the
      #   buffer at `uri`. Returns nil when the URI isn't open or
      #   doesn't parse cleanly enough to surface symbols — LSP
      #   clients fall back to no-outline in that case.
      def provide(uri)
        path = Uri.to_path(uri)
        return nil if path.nil?

        entry = @buffer_table[uri]
        return nil if entry.nil?

        parse_result = Prism.parse(entry.bytes, filepath: path,
                                                version: @project_context.configuration.target_ruby)
        # Tolerate partial parse errors: walk what Prism gave us
        # anyway. Editors prefer a stale outline over no outline.
        walk_top_level(parse_result.value)
      end

      private

      def walk_top_level(root)
        symbols = []
        each_decl(root, in_namespace: false) { |s| symbols << s }
        symbols
      end

      def each_decl(node, in_namespace:, &block)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode
          children = []
          each_decl(node.body, in_namespace: true) { |child| children << child } if node.body
          block.call(class_symbol(node, children))
        when Prism::ModuleNode
          children = []
          each_decl(node.body, in_namespace: true) { |child| children << child } if node.body
          block.call(module_symbol(node, children))
        when Prism::DefNode
          block.call(def_symbol(node, in_namespace: in_namespace))
        else
          node.compact_child_nodes.each do |child|
            each_decl(child, in_namespace: in_namespace, &block)
          end
        end
      end

      def class_symbol(node, children)
        {
          name: qualified_name_of(node.constant_path),
          kind: KIND_CLASS,
          range: range_from(node.location),
          selectionRange: range_from(node.constant_path.location),
          children: children
        }
      end

      def module_symbol(node, children)
        {
          name: qualified_name_of(node.constant_path),
          kind: KIND_MODULE,
          range: range_from(node.location),
          selectionRange: range_from(node.constant_path.location),
          children: children
        }
      end

      def def_symbol(node, in_namespace:)
        name = node.name.to_s
        # `def self.foo` (singleton-class) → singleton-method shape.
        # We surface the same as instance methods in v1 (LSP kind
        # has no distinct "ClassMethod" code); the textual `self.`
        # prefix preserves the distinction visually.
        display_name = node.receiver.is_a?(Prism::SelfNode) ? "self.#{name}" : name
        {
          name: display_name,
          kind: in_namespace ? KIND_METHOD : KIND_FUNCTION,
          range: range_from(node.location),
          selectionRange: range_from(node.name_loc),
          children: []
        }
      end

      # Renders a `ConstantReadNode` / `ConstantPathNode` as its
      # fully-qualified name string (e.g. `Foo::Bar::Baz`). Returns
      # the slot-name source when the node shape is unrecognised so
      # the outline still has something to display.
      def qualified_name_of(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parent = node.parent.nil? ? nil : qualified_name_of(node.parent)
          parent.nil? ? node.name.to_s : "#{parent}::#{node.name}"
        else
          node.respond_to?(:slice) ? node.slice : "<unknown>"
        end
      end

      # LSP `Range` is 0-based start + end with `character` in
      # UTF-16 code units. Slice 6 emits byte columns (correct for
      # ASCII source); UTF-16 conversion stays queued per design
      # doc § "Open questions".
      def range_from(location)
        {
          start: { line: location.start_line - 1, character: location.start_column },
          end: { line: location.end_line - 1, character: location.end_column }
        }
      end
    end
  end
end
