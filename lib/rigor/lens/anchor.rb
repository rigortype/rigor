# frozen_string_literal: true

require_relative "../hashing/xxh3"

module Rigor
  module Lens
    # A site's anchor and contract-comment span (docs/internal-spec/lens.md § Anchors). The hashed material is the
    # contract comment lines above the declaration (`#:`, `@rbs`, `@extrbs` and their continuation lines), the
    # declaration's own bytes, and a `#:` comment trailing its last line. Documentation prose is not part of it.
    class Anchor
      Result = Data.define(:token, :line, :contract_comments)

      # rbs-inline's annotation grammar (`#:`, `#[`, `#\s*@rbs`) plus `@extrbs`, matched from the `#`.
      CONTRACT_COMMENT = /\A#(?::|\[|\s*@rbs\b|\s*@extrbs\b)/
      # A `#:nodoc:`-style RDoc directive, which the rbs-inline plugin neutralises rather than reads.
      RDOC_DIRECTIVE = /\A#:[a-z_][\w-]*:/
      # A kept line that later comment lines may continue, with the spaces between its `#` and the tag.
      CONTINUED_TAG = /\A#( *)@(?:rbs|extrbs)\b/

      # @param source — the file's bytes (binary String)
      # @param comments — the file's `Prism::Comment` list
      def initialize(source, comments)
        @source = source.b
        @line_starts = [0]
        @source.each_byte.with_index { |byte, index| @line_starts << (index + 1) if byte == 10 }
        @comment_by_line = {}
        comments.each do |comment|
          next unless comment.is_a?(Prism::InlineComment)

          @comment_by_line[comment.location.start_line] = comment
        end
      end

      # The anchor of the declaration spanning bytes `start_offset...end_offset` and lines `start_line..end_line`.
      def for_span(start_offset, end_offset, start_line, end_line)
        leading = leading_contract_comments(start_line)
        trailing = trailing_contract_comment(end_line, end_offset)
        material = +"".b
        leading.each { |comment| material << line_text_from(comment.location.start_offset) << "\n" }
        material << @source.byteslice(start_offset, end_offset - start_offset)
        material << "\n" << line_text_from(trailing.location.start_offset) if trailing
        line = leading.empty? ? start_line : leading.first.location.start_line
        Result.new(token: "#{line}:#{Hashing::XXH3.anchor_hash(material)}", line: line,
                   contract_comments: leading + [trailing].compact)
      end

      # The anchor of a declaration that carries no contract comments: its own bytes alone.
      def bare(start_offset, end_offset, start_line)
        material = @source.byteslice(start_offset, end_offset - start_offset)
        Result.new(token: "#{start_line}:#{Hashing::XXH3.anchor_hash(material)}", line: start_line,
                   contract_comments: [])
      end

      private

      # The contract comments among the contiguous comment-only lines directly above `start_line`, in file order,
      # with rbs-inline's continuation lines below a kept `@rbs` / `@extrbs` line.
      def leading_contract_comments(start_line)
        run = []
        line = start_line - 1
        while line >= 1 && (comment = comment_only_line(line))
          run.unshift(comment)
          line -= 1
        end
        kept = []
        tag_indent = nil
        run.each do |comment|
          text = comment_text(comment)
          if tag_indent && hash_indent(text) > tag_indent
            kept << comment
            next
          end

          tag_indent = nil
          next unless contract_comment?(text)

          kept << comment
          continued = text.match(CONTINUED_TAG)
          tag_indent = continued && continued[1].size
        end
        kept
      end

      def trailing_contract_comment(end_line, end_offset)
        comment = @comment_by_line[end_line]
        return nil if comment.nil? || comment.location.start_offset < end_offset

        text = comment_text(comment)
        contract_comment?(text) && text.start_with?("#:") ? comment : nil
      end

      def contract_comment?(text)
        text.match?(CONTRACT_COMMENT) && !text.match?(RDOC_DIRECTIVE)
      end

      # The spaces between a comment's `#` and its first non-space byte.
      def hash_indent(text)
        text[/\A#( *)/, 1].size
      end

      # The comment on `line` when nothing but whitespace precedes it.
      def comment_only_line(line)
        comment = @comment_by_line[line]
        return nil if comment.nil?

        prefix = @source.byteslice(@line_starts[line - 1], comment.location.start_offset - @line_starts[line - 1])
        prefix.match?(/\A[ \t]*\z/) ? comment : nil
      end

      # The comment's text from its `#`, without a line terminator.
      def comment_text(comment)
        comment.location.slice.b.chomp.delete_suffix("\r")
      end

      # The bytes from `offset` to the end of its line, without the line terminator.
      def line_text_from(offset)
        line_end = @source.index("\n", offset) || @source.bytesize
        @source.byteslice(offset, line_end - offset).delete_suffix("\r")
      end
    end
  end
end
