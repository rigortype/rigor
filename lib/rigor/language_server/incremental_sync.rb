# frozen_string_literal: true

require "strscan"

module Rigor
  module LanguageServer
    # Applies LSP `TextDocumentContentChangeEvent`s to a held buffer under `TextDocumentSyncKind::Incremental`.
    #
    # ## Why the offsets need care
    #
    # An LSP `Position#character` counts **UTF-16 code units** (`positionEncoding: "utf-16"`, the protocol
    # default and the only encoding every client supports), while a Ruby String indexes by **codepoint**. The
    # two agree for every character in the Basic Multilingual Plane — all of ASCII, Latin-1, Greek, Cyrillic,
    # kana and common kanji — and disagree above U+FFFF, where an emoji or a CJK-extension ideograph is ONE
    # Ruby character and TWO UTF-16 code units. Reading one as the other shifts every subsequent edit on the
    # line, and a shifted edit desynchronises the server's text from what the editor shows for the rest of the
    # session: every diagnostic after that point lands on the wrong span, silently.
    #
    # So the conversion is explicit. {.utf16_offset_to_index} walks the line one character at a time, charging
    # 2 code units for a codepoint above U+FFFF and 1 for everything else, and stops when the requested count
    # is spent. An all-ASCII line short-circuits the walk, since there the offset IS the index — that is the
    # keystroke path, and `String#ascii_only?` answers it from the cached coderange.
    #
    # ## Failure is a resync, never a guess
    #
    # A change whose shape cannot be applied confidently raises {UnappliableChange} rather than producing a
    # best-effort buffer: {BufferTable#apply_changes} then keeps the last known-good text and marks the URI
    # desynchronised, which suppresses diagnostics until a full-text change or a re-open re-establishes the
    # buffer. A stale-but-flagged buffer is recoverable; a silently wrong one is not.
    module IncrementalSync
      # Raised when a `contentChanges` entry cannot be applied to the held text: a malformed payload, a
      # position that is not a non-negative Integer pair, or a range edit against a buffer the server never
      # received a `didOpen` / full-text change for.
      class UnappliableChange < StandardError; end

      # LSP considers a line delimited by `\n`, `\r\n`, or a lone `\r`. Ruby's own line splitting only knows
      # `\n`, so the scan is explicit.
      LINE_TERMINATOR = /\r\n|\n|\r/

      # UTF-8 encodes exactly the codepoints above the BMP — the ones UTF-16 must encode as a surrogate pair —
      # in four bytes. So a character's UTF-8 byte length answers "one code unit or two?" without decoding it.
      SURROGATE_PAIR_BYTES = 4

      module_function

      # Applies every change in order, each against the result of the previous — the LSP contract for a
      # multi-change `didChange` notification.
      #
      # @rbs text: String? -- The held buffer text; nil when no buffer is open for the URI.
      # @rbs changes: Array[Hash[untyped, untyped]] -- The `contentChanges` array.
      # @rbs return: String -- The new buffer text. Raises UnappliableChange if any change cannot be applied.
      def apply_all(text, changes)
        raise UnappliableChange, "contentChanges must be an Array, got #{changes.class}" unless changes.is_a?(Array)

        changes.reduce(text) { |acc, change| apply(acc, change) }
      end

      # Applies one `TextDocumentContentChangeEvent`.
      #
      # Two shapes are legal under incremental sync. Without `range` the entry is the full new document text
      # (clients fall back to it for a paste, an undo, or a file reload, and it stays legal under
      # `Incremental`); with `range` it replaces the spanned text. `rangeLength` is the deprecated pre-3.16
      # companion to `range` and is accepted-but-ignored: it is redundant with `range`, historically ambiguous
      # about its units, and `range` is the authoritative field.
      #
      # Raises UnappliableChange
      def apply(text, change)
        raise UnappliableChange, "contentChanges entry must be a Hash, got #{change.class}" unless change.is_a?(Hash)

        replacement = change[:text]
        raise UnappliableChange, "contentChanges entry has no `text`" unless replacement.is_a?(String)

        range = change[:range]
        return replacement.dup if range.nil?
        raise UnappliableChange, "`range` must be a Hash, got #{range.class}" unless range.is_a?(Hash)
        raise UnappliableChange, "range edit for a URI with no open buffer" if text.nil?

        splice(text, range, replacement)
      end

      # Replaces the `range` span of `text` with `replacement`.
      #
      # Text that is not valid UTF-8 makes the line scan itself raise. That is not a buffer JSON transport can
      # deliver, but if one appears there is no offset arithmetic to be confident about, so it becomes a
      # resync like any other unappliable shape.
      def splice(text, range, replacement)
        spans = line_spans(text)
        from = char_offset(text, spans, range[:start])
        # A client that inverts the range — or an `end` rounded below `start` off a mid-surrogate
        # position — would otherwise slice backwards; collapse to an insertion at `from` instead.
        to = char_offset(text, spans, range[:end]).clamp(from, text.length)
        "#{text[0, from]}#{replacement}#{text[to..]}"
      rescue ArgumentError, Encoding::CompatibilityError => e
        raise UnappliableChange, "held text is not valid UTF-8: #{e.message}"
      end

      # @rbs return: Array[[Integer, Integer]] --
      #   One `[content_start, content_end]` pair per line, in Ruby character indices. `content_end` excludes the line
      #   terminator, so it doubles as the clamp target for an over-long `character`. A trailing terminator yields a
      #   final empty span — the virtual last line an editor puts the cursor on, and the anchor for an end-of-document
      #   insert.
      def line_spans(text)
        spans = []
        scanner = StringScanner.new(text)
        start = 0
        while scanner.skip_until(LINE_TERMINATOR)
          stop = scanner.charpos
          spans << [start, stop - scanner.matched.length]
          start = stop
        end
        spans << [start, text.length]
        spans
      end

      # Converts an LSP `Position` into a Ruby character index into `text`.
      #
      # A `line` past the last line clamps to the end of the document rather than raising: clients do address
      # the position one past the final line, and the clamp is what the protocol's own end-of-document
      # convention implies.
      def char_offset(text, spans, position)
        line = position_field(position, :line)
        character = position_field(position, :character)
        return text.length if line >= spans.length

        start, stop = spans[line]
        start + utf16_offset_to_index(text[start...stop], character)
      end

      # Converts a UTF-16 code-unit offset into `line` to a Ruby character index into the same line.
      #
      # Clamps an offset past the end of the line to the line length, per LSP's rule that a `character`
      # greater than the line length defaults back to the line length.
      def utf16_offset_to_index(line, units)
        # Fast path: on an all-ASCII line one UTF-16 code unit is one Ruby character, so the offset is the
        # index. This is the keystroke case, and `ascii_only?` reads the string's cached coderange.
        return units.clamp(0, line.length) if line.ascii_only?

        index = 0
        remaining = units
        line.each_char do |char|
          break if remaining <= 0

          remaining -= char.bytesize == SURROGATE_PAIR_BYTES ? 2 : 1
          index += 1
        end
        # `remaining` below zero means the offset addressed the low half of a surrogate pair — a position no
        # conforming client sends. Round DOWN to the character boundary; splitting the pair is not an option.
        remaining.negative? ? index - 1 : index
      end

      def position_field(position, key)
        value = position.is_a?(Hash) ? position[key] : nil
        return value if value.is_a?(Integer) && !value.negative?

        raise UnappliableChange, "position `#{key}` must be a non-negative Integer, got #{value.inspect}"
      end
    end
  end
end
