# frozen_string_literal: true

require "prism"

module Rigor
  module Source
    # Locates the deepest Prism AST node enclosing a given source position.
    #
    # The locator works on byte offsets internally so that multibyte source
    # text behaves consistently with Prism, which itself reports offsets in
    # bytes. Convenience constructors translate from `(line, column)` pairs.
    #
    # Lines are 1-indexed (matching editor / Prism / gcc conventions).
    # Columns are 1-indexed when supplied via the `(line, column)` API; this
    # matches the canonical `file.rb:line:col` form most tools emit. Internal
    # offsets remain 0-indexed bytes.
    #
    # The locator is read-only: a single instance binds to one source buffer
    # and AST root, and queries are pure functions of the byte offset.
    class NodeLocator
      class OutOfRangeError < StandardError; end

      class << self
        # @param source [String]
        # @param root [Prism::Node]
        # @param line [Integer] 1-indexed line number
        # @param column [Integer] 1-indexed column number (byte index within the line)
        # @return [Prism::Node, nil]
        def at_position(source:, root:, line:, column:)
          new(source: source, root: root).at_position(line: line, column: column)
        end

        # @param root [Prism::Node]
        # @param offset [Integer] 0-indexed byte offset
        # @return [Prism::Node, nil]
        def at_offset(root:, offset:)
          new(source: nil, root: root).at_offset(offset)
        end
      end

      # @param source [String, nil] used by `#at_position`; may be omitted when only `#at_offset` is needed.
      # @param root [Prism::Node]
      def initialize(source:, root:)
        @source = source
        @root = root
      end

      # Resolve a `(line, column)` pair (1-indexed) to the deepest enclosing node.
      #
      # @raise [OutOfRangeError] if the line or column falls outside the source buffer.
      def at_position(line:, column:)
        offset = position_to_offset(line, column)
        at_offset(offset)
      end

      # Resolve a byte offset (0-indexed) to the deepest enclosing node.
      def at_offset(offset)
        descend(@root, offset)
      end

      # Translate a `(line, column)` pair into a 0-indexed byte offset for the
      # bound source buffer.
      def position_to_offset(line, column)
        raise ArgumentError, "source buffer required for position lookup" if @source.nil?
        raise OutOfRangeError, "line must be >= 1, got #{line}" if line < 1
        raise OutOfRangeError, "column must be >= 1, got #{column}" if column < 1

        offset = 0
        current_line = 1
        @source.each_line do |chunk|
          break if current_line == line

          offset += chunk.bytesize
          current_line += 1
        end

        raise OutOfRangeError, "line #{line} is past the end of the source buffer" if current_line != line

        offset + (column - 1)
      end

      private

      def descend(node, offset)
        return nil unless node.is_a?(Prism::Node)
        return nil unless contains?(node, offset)

        node.compact_child_nodes.each do |child|
          deeper = descend(child, offset)
          return deeper if deeper
        end

        node
      end

      def contains?(node, offset)
        location = node.location
        return false if location.nil?

        location.start_offset <= offset && offset < location.end_offset
      end
    end
  end
end
