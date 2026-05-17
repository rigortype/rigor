# frozen_string_literal: true

require "prism"

require_relative "uri"

module Rigor
  module LanguageServer
    # Answers `textDocument/foldingRange` requests. Walks the Prism
    # AST and emits one `FoldingRange` per foldable construct:
    # `class` / `module` / `def` / `singleton class << self` /
    # block (`do…end` or `{…}`). Skips single-line constructs
    # (start_line == end_line) since there's nothing to fold.
    #
    # Ranges are LSP 0-based. `startLine` is the line containing
    # the opening keyword (`class`, `def`); `endLine` is the last
    # line OF the body — one line before the `end` keyword — so
    # collapsed view shows the opener intact and hides the body
    # only.
    class FoldingRangeProvider
      def initialize(buffer_table:, project_context:)
        @buffer_table = buffer_table
        @project_context = project_context
      end

      # @return [Array<Hash>, nil] LSP `FoldingRange[]` for the
      #   buffer, or nil when the URI isn't open / parseable.
      def provide(uri)
        path = Uri.to_path(uri)
        return nil if path.nil?

        entry = @buffer_table[uri]
        return nil if entry.nil?

        parse_result = Prism.parse(entry.bytes, filepath: path,
                                                version: @project_context.configuration.target_ruby)
        # Tolerate partial parse errors — fold whatever AST Prism
        # produced. Editors prefer a stale outline / fold map
        # over none.
        ranges = []
        walk(parse_result.value, ranges)
        ranges
      end

      private

      def walk(node, ranges)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode,
             Prism::SingletonClassNode, Prism::DefNode,
             Prism::BlockNode
          add_range(node, ranges)
        end
        node.compact_child_nodes.each { |child| walk(child, ranges) }
      end

      def add_range(node, ranges)
        loc = node.location
        start_line = loc.start_line - 1
        # `end_line` includes the line of the `end` keyword.
        # Folding should hide the body and leave both the opener
        # AND the `end` keyword visible — so endLine is one line
        # before `end`. When the body is a single line, that
        # makes start == end (one-line fold), which most editors
        # skip; we filter those out.
        end_line = loc.end_line - 2
        return if end_line <= start_line

        ranges << { startLine: start_line, endLine: end_line }
      end
    end
  end
end
