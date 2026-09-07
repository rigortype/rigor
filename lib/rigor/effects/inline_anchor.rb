# frozen_string_literal: true

module Rigor
  module Effects
    # Maps a position read out of a **synthesized** RBS buffer back onto the Ruby file the author
    # actually wrote in ([#432](https://github.com/rigortype/rigor/issues/432)).
    #
    # An rbs-inline annotation never reaches the envelope reader as the line the author typed. The
    # plugin hands `RBS::Inline::Writer`'s output to the loader as a `virtual:rbs-inline:<path>.rb`
    # buffer, and that output is a *fresh document*: bodies are gone, the members it emits are the
    # signatures rather than the `def`s, and every annotation is re-emitted above its member on a line
    # of the writer's choosing. The buffer name still names the `.rb`, so a location rendered straight
    # off `RBS::Location` reads `app/models/change.rb:5` — the right file, and a line number that
    # belongs to a document nobody has. On a file with a licence header it lands inside the copyright
    # notice and is not even visibly wrong.
    #
    # ## Why the answer is the annotation's own text, matched by ordinal
    #
    # There is no line table to consult: upstream's writer emits text and keeps no mapping, and the
    # synthesized buffer is what the RBS parser saw. What both documents *do* share is the author's own
    # spelling — `%a{pure}` reaches the buffer verbatim — and their order, because the writer emits
    # members in source order. So the k-th `%a{pure}` of the buffer is the k-th `%a{pure}` of the `.rb`,
    # and matching on the ordinal is what keeps a file with several identically-bounded methods from
    # pointing all of them at the first one. A plain "find the text" search cannot tell them apart, and
    # a fixed offset would encode one fixture's licence header as if it were a rule.
    #
    # Two filters make the two lists comparable:
    #
    # - in the buffer, only a line whose own text *is* the annotation counts. The writer also echoes the
    #   author's comment block above each member, so `# @rbs %a{pure}` appears there too and would
    #   double every count;
    # - in the `.rb`, only a comment line counts, so a `%a{…}` inside a string literal or a heredoc is
    #   never mistaken for a declaration.
    #
    # Every step degrades to the buffer line it was given: a `.rb` that cannot be read, a spelling with
    # no match, a writer that some day stops preserving order. A position one line off is a smaller
    # harm than a raised exception on a run that had a real finding to report.
    class InlineAnchor
      RUBY_EXTENSION = ".rb"
      private_constant :RUBY_EXTENSION

      # An RBS annotation as the parser sees it: the line's own text, not a comment mentioning one.
      ANNOTATION_PREFIX = "%a{"
      private_constant :ANNOTATION_PREFIX

      COMMENT_PREFIX = "#"
      private_constant :COMMENT_PREFIX

      SPELLING_PATTERN = /%a\{[^}]*\}/
      private_constant :SPELLING_PATTERN

      # @rbs path: String -- The buffer's readable path, as {SignatureSources.source_path} renders it.
      # @rbs buffer: String -- The synthesized RBS the position was read out of.
      # @rbs return: InlineAnchor? --
      #   Nil when `path` is not a Ruby file — a real `.rbs` needs no mapping, and its own line numbers are already
      #   the ones a reader can open.
      def self.for(path:, buffer:)
        return nil unless path.to_s.end_with?(RUBY_EXTENSION)

        new(path: path.to_s, buffer: buffer.to_s)
      end

      # One-shot form, for a caller that holds a `[path, buffer, line]` triple and no anchor.
      #
      # @rbs return: Integer -- The `.rb` line, or `buffer_line` unchanged when there is nothing to map.
      def self.ruby_line(path:, buffer:, buffer_line:, spelling: nil)
        anchor = self.for(path: path, buffer: buffer)
        return buffer_line if anchor.nil?

        anchor.line_for(buffer_line, spelling: spelling)
      end

      def initialize(path:, buffer:)
        @path = path
        @buffer = buffer
        @ruby_lines = nil
      end

      # @rbs buffer_line: Integer -- 1-based, counting into the synthesized buffer.
      # @rbs spelling: String? --
      #   The annotation's own text (`"%a{pure}"`); read off the buffer line when the caller does not already hold it.
      # @rbs return: Integer -- The 1-based line of the same annotation in the Ruby file.
      def line_for(buffer_line, spelling: nil)
        spelling = normalize(spelling) || spelling_at(buffer_line)
        return buffer_line if spelling.nil?

        candidates = ruby_lines.filter_map { |number, text| number if text.include?(spelling) }
        return buffer_line if candidates.empty?

        candidates[ordinal_of(buffer_line, spelling)] || candidates.first
      end

      private

      # The spelling as it appears in both documents. Callers hold it as `"%a{#{annotation.string}}"`,
      # which is already that form; anything else is read for its annotation text or dropped.
      def normalize(spelling)
        spelling.to_s[SPELLING_PATTERN]
      end

      def spelling_at(buffer_line)
        @buffer.each_line.with_index(1) do |text, number|
          return text[SPELLING_PATTERN] if number == buffer_line
        end
        nil
      end

      # How many annotations of the same spelling the buffer declares before `buffer_line`. Comment
      # lines are skipped: the writer echoes the author's `# @rbs %a{…}` above the annotation it
      # generates, and counting both would land every lookup one match too far down the file.
      def ordinal_of(buffer_line, spelling)
        seen = 0
        @buffer.each_line.with_index(1) do |text, number|
          break if number >= buffer_line

          stripped = text.lstrip
          seen += 1 if stripped.start_with?(ANNOTATION_PREFIX) && stripped.include?(spelling)
        end
        seen
      end

      # The Ruby file's comment lines, as `[line number, text]`. Read once, and only for a position that
      # is already going to be rendered.
      def ruby_lines
        @ruby_lines ||= begin
          File.foreach(@path).with_index(1).filter_map do |text, number|
            [number, text] if text.lstrip.start_with?(COMMENT_PREFIX)
          end
        rescue StandardError
          [].freeze
        end
      end
    end
  end
end
