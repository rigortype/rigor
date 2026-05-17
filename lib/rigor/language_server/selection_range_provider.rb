# frozen_string_literal: true

require "prism"

require_relative "uri"

module Rigor
  module LanguageServer
    # Answers `textDocument/selectionRange` requests. For each
    # position, returns a linked list of SelectionRange entries —
    # innermost first, each pointing at its `parent` (the next-
    # wider expression). Editors use this for "expand selection":
    # one keystroke moves up the chain, another moves further out,
    # all the way to the root.
    class SelectionRangeProvider
      def initialize(buffer_table:, project_context:)
        @buffer_table = buffer_table
        @project_context = project_context
      end

      # @param positions [Array<Hash>] LSP `Position[]` — each
      #   `{ line:, character: }` 0-based.
      # @return [Array<Hash>, nil] one `SelectionRange` per
      #   position, or nil when the URI / buffer isn't resolvable.
      def provide(uri, positions)
        path = Uri.to_path(uri)
        return nil if path.nil?

        entry = @buffer_table[uri]
        return nil if entry.nil?

        parse_result = Prism.parse(entry.bytes, filepath: path,
                                   version: @project_context.configuration.target_ruby)
        root = parse_result.value

        positions.map do |pos|
          offset = byte_offset_for(entry.bytes, pos.fetch(:line), pos.fetch(:character))
          next nil if offset.nil?

          build_chain(root, offset)
        end
      end

      private

      # Walks the AST top-down; each node whose location encloses
      # `offset` gets appended to the chain. Returns root→innermost.
      def ancestor_chain(node, offset, chain = [])
        return chain unless node.is_a?(Prism::Node)
        return chain unless node.location && offset_in?(node.location, offset)

        chain << node
        node.compact_child_nodes.each { |child| ancestor_chain(child, offset, chain) }
        chain
      end

      def offset_in?(location, offset)
        offset.between?(location.start_offset, location.end_offset)
      end

      # Folds the root→innermost chain into the LSP `SelectionRange`
      # linked-list shape — innermost on the outside (the request's
      # return value) with `parent` chained outward. Editor "expand
      # selection" follows `.parent` one step per invocation.
      def build_chain(root, offset)
        chain = ancestor_chain(root, offset)
        return nil if chain.empty?

        chain.reduce(nil) do |parent, node|
          { range: lsp_range(node), parent: parent }
        end
      end

      def lsp_range(node)
        loc = node.location
        {
          start: { line: loc.start_line - 1, character: loc.start_column },
          end:   { line: loc.end_line - 1,   character: loc.end_column }
        }
      end

      def byte_offset_for(bytes, line, character)
        offset = 0
        bytes.each_line.with_index do |line_bytes, idx|
          return offset + character if idx == line

          offset += line_bytes.bytesize
        end
        nil
      end
    end
  end
end
