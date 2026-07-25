# frozen_string_literal: true

require "rigor/language_server/incremental_sync"

# An INDEPENDENT model of the same edit, kept deliberately unlike the implementation: it transcodes the whole
# document to UTF-16 with Ruby's own encoder, splices in the code-unit array the protocol actually talks about,
# and transcodes back. Nothing here re-derives "how wide is this character" the way `IncrementalSync` does, so
# agreement between the two is evidence about the offset arithmetic rather than a restatement of it.
module Utf16Reference
  module_function

  def to_units(str)
    str.encode(Encoding::UTF_16LE).unpack("v*")
  end

  def from_units(units)
    units.pack("v*").force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8)
  end

  def width(char)
    char.encode(Encoding::UTF_16LE).bytesize / 2
  end

  # Absolute UTF-16 offset of an LSP position within `text` (documents here use `\n` only).
  def absolute_offset(text, line, character)
    lines = text.split("\n", -1)
    return to_units(text).length if line >= lines.length

    preceding = lines[0, line].sum { |one| to_units(one).length + 1 }
    preceding + [character, to_units(lines[line]).length].min
  end

  # Applies a range edit to the WHOLE document in UTF-16 space.
  def splice(text, range, replacement)
    from = absolute_offset(text, range[:start][:line], range[:start][:character])
    to = absolute_offset(text, range[:end][:line], range[:end][:character])
    units = to_units(text)
    from_units(units[0, from] + to_units(replacement) + units[to..])
  end

  # Every UTF-16 offset in `line_text` that sits on a character boundary — the only offsets a conforming
  # client emits.
  def boundaries(line_text)
    line_text.chars.each_with_object([0]) { |char, acc| acc << (acc.last + width(char)) }
  end
end

RSpec.describe Rigor::LanguageServer::IncrementalSync do
  def edit(from_line, from_char, to_line, to_char, text, **extra)
    {
      range: {
        start: { line: from_line, character: from_char },
        end: { line: to_line, character: to_char }
      },
      text: text
    }.merge(extra)
  end

  describe ".apply — ASCII range edits" do
    it "replaces the spanned text on one line" do
      expect(described_class.apply("x = 1\ny = 2\n", edit(0, 4, 0, 5, "42"))).to eq("x = 42\ny = 2\n")
    end

    it "inserts at a zero-width range" do
      expect(described_class.apply("ab\n", edit(0, 1, 0, 1, "XY"))).to eq("aXYb\n")
    end

    it "deletes a whole line when the replacement is empty" do
      expect(described_class.apply("one\ntwo\nthree\n", edit(1, 0, 2, 0, ""))).to eq("one\nthree\n")
    end

    it "deletes across a line boundary, joining the two lines" do
      expect(described_class.apply("one\ntwo\n", edit(0, 3, 1, 0, ""))).to eq("onetwo\n")
    end

    it "clamps a character past the end of the line to the line length (LSP § Position)" do
      expect(described_class.apply("ab\ncd\n", edit(0, 99, 0, 99, "!"))).to eq("ab!\ncd\n")
    end
  end

  describe ".apply — UTF-16 offsets around non-BMP characters" do
    # `a = "🍣"` is 7 Ruby characters but 8 UTF-16 code units: the sushi is one character and TWO units.
    let(:source) { %(a = "🍣"\nb = 1\n) }

    it "the fixture really does disagree between the two measures" do
      first_line = source.lines.first.chomp
      expect(first_line.length).to eq(7)
      expect(Utf16Reference.to_units(first_line).length).to eq(8)
    end

    it "appends at the end of the line (offset 8 — past the Ruby length of 7)" do
      expect(described_class.apply(source, edit(0, 8, 0, 8, ".freeze"))).to eq(%(a = "🍣".freeze\nb = 1\n))
    end

    it "inserts immediately AFTER the non-BMP character (offset 7)" do
      expect(described_class.apply(source, edit(0, 7, 0, 7, "!"))).to eq(%(a = "🍣!"\nb = 1\n))
    end

    it "inserts immediately BEFORE the non-BMP character (offset 5)" do
      expect(described_class.apply(source, edit(0, 5, 0, 5, "!"))).to eq(%(a = "!🍣"\nb = 1\n))
    end

    it "replaces the non-BMP character itself (a two-unit span)" do
      expect(described_class.apply(source, edit(0, 5, 0, 7, "🍺"))).to eq(%(a = "🍺"\nb = 1\n))
    end

    it "counts several non-BMP characters cumulatively" do
      text = "# 😀😀😀 tail\n"
      # Two units each: `# ` = 2, three faces = 6, so offset 8 is just past the last one.
      expect(described_class.apply(text, edit(0, 8, 0, 8, "|"))).to eq("# 😀😀😀| tail\n")
    end

    it "keeps BMP-but-not-ASCII characters at one unit each" do
      # Japanese kana / kanji are BMP: one Ruby character, one UTF-16 code unit.
      expect(described_class.apply("# 日本語\n", edit(0, 4, 0, 4, "!"))).to eq("# 日本!語\n")
    end

    it "reaches a line that FOLLOWS a non-BMP line at the right offset" do
      expect(described_class.apply(source, edit(1, 4, 1, 5, "2"))).to eq(%(a = "🍣"\nb = 2\n))
    end

    it "rounds a mid-surrogate offset DOWN to the character boundary rather than splitting the pair" do
      # Offset 6 addresses the low half of the sushi's surrogate pair — not a position a conforming client
      # sends. Rounding down puts the insert before the character; the string stays well-formed either way.
      result = described_class.apply(source, edit(0, 6, 0, 6, "!"))
      expect(result).to eq(%(a = "!🍣"\nb = 1\n))
      expect(result).to be_valid_encoding
    end
  end

  describe ".apply — document-edge and terminator handling" do
    it "inserts on the virtual last line after a trailing newline" do
      expect(described_class.apply("x = 1\n", edit(1, 0, 1, 0, "y = 2\n"))).to eq("x = 1\ny = 2\n")
    end

    it "appends at the very end of a document with no trailing newline" do
      expect(described_class.apply("x = 1", edit(0, 5, 0, 5, "\ny = 2"))).to eq("x = 1\ny = 2")
    end

    it "clamps a line past the end of the document to the end of the document" do
      expect(described_class.apply("x = 1\n", edit(99, 0, 99, 0, "tail"))).to eq("x = 1\ntail")
    end

    it "handles CRLF line terminators" do
      expect(described_class.apply("a\r\nb\r\n", edit(1, 0, 1, 1, "B"))).to eq("a\r\nB\r\n")
    end

    it "handles a lone CR line terminator" do
      expect(described_class.apply("a\rb\r", edit(1, 0, 1, 1, "B"))).to eq("a\rB\r")
    end

    it "collapses an inverted range to an insertion rather than slicing backwards" do
      expect(described_class.apply("abcd\n", edit(0, 3, 0, 1, "X"))).to eq("abcXd\n")
    end
  end

  describe ".apply — non-range and deprecated shapes" do
    it "treats an entry with no range as the full new document text" do
      expect(described_class.apply("old\n", { text: "brand new\n" })).to eq("brand new\n")
    end

    it "accepts a no-range entry even when no buffer is held" do
      expect(described_class.apply(nil, { text: "first\n" })).to eq("first\n")
    end

    it "ignores the deprecated rangeLength and trusts the range" do
      change = edit(0, 0, 0, 3, "X", rangeLength: 999)
      expect(described_class.apply("abcdef\n", change)).to eq("Xdef\n")
    end

    it "returns a mutable copy for the full-replacement form" do
      replacement = "text\n"
      expect(described_class.apply("old\n", { text: replacement })).not_to be(replacement)
    end
  end

  describe ".apply — shapes that fall back to a resync" do
    it "refuses a range edit when no buffer is held" do
      expect { described_class.apply(nil, edit(0, 0, 0, 1, "x")) }
        .to raise_error(described_class::UnappliableChange, /no open buffer/)
    end

    it "refuses a position whose fields are missing" do
      expect { described_class.apply("x\n", { range: { start: {}, end: {} }, text: "y" }) }
        .to raise_error(described_class::UnappliableChange, /non-negative Integer/)
    end

    it "refuses a negative position" do
      expect { described_class.apply("x\n", edit(0, -1, 0, 0, "y")) }
        .to raise_error(described_class::UnappliableChange, /non-negative Integer/)
    end

    it "refuses an entry with no text" do
      expect { described_class.apply("x\n", { range: nil }) }
        .to raise_error(described_class::UnappliableChange, /no `text`/)
    end

    it "refuses to compute offsets in text that is not valid UTF-8, rather than raising out of the dispatcher" do
      text = +"a\xFFb\n"
      text.force_encoding(Encoding::UTF_8)

      expect { described_class.apply(text, edit(0, 0, 0, 0, "!")) }
        .to raise_error(described_class::UnappliableChange, /not valid UTF-8/)
    end

    it "refuses a non-Hash entry" do
      expect { described_class.apply("x\n", "oops") }
        .to raise_error(described_class::UnappliableChange, /must be a Hash/)
    end
  end

  describe ".apply_all — multiple changes in one notification" do
    it "applies them in order, each against the result of the previous" do
      # The second edit's offsets only make sense against the FIRST edit's result: after `x` becomes `xyz`,
      # (0,3) is the end of the line.
      changes = [edit(0, 1, 0, 1, "yz"), edit(0, 3, 0, 3, " = 1")]
      expect(described_class.apply_all("x\n", changes)).to eq("xyz = 1\n")
    end

    it "lets a later change re-target a line the earlier one created" do
      changes = [edit(0, 0, 0, 0, "first\n"), edit(1, 0, 1, 0, "second-")]
      expect(described_class.apply_all("last\n", changes)).to eq("first\nsecond-last\n")
    end

    it "applies a mid-list full-replacement entry as a reset" do
      changes = [edit(0, 0, 0, 1, "Z"), { text: "reset\n" }, edit(0, 5, 0, 5, "!")]
      expect(described_class.apply_all("abc\n", changes)).to eq("reset!\n")
    end

    it "tracks non-BMP width across successive edits on one line" do
      changes = [edit(0, 0, 0, 0, "🍣"), edit(0, 2, 0, 2, "x")]
      expect(described_class.apply_all("", changes)).to eq("🍣x")
    end

    it "rejects a contentChanges payload that is not an Array" do
      expect { described_class.apply_all("x\n", { text: "y" }) }
        .to raise_error(described_class::UnappliableChange, /must be an Array/)
    end
  end

  describe "round-trip property against the whole-document UTF-16 model" do
    # A seeded pseudo-random edit stream: every step applies the same change incrementally and to the whole
    # document (in UTF-16 code-unit space, via Ruby's transcoder) and asserts the two agree. Any drift in the
    # offset arithmetic shows up as a divergence within a handful of steps.
    let(:replacements) { ["", "x", "\n", "🍣", "あ", "𝔸b", "def foo\n  1\nend\n", "# 😀 ok"] }

    def random_position(text, rng)
      lines = text.split("\n", -1)
      line = rng.rand(lines.length)
      [line, Utf16Reference.boundaries(lines[line]).sample(random: rng)]
    end

    def random_change(text, rng)
      from_line, from_char = random_position(text, rng)
      to_line, to_char = random_position(text, rng)
      if to_line < from_line ||
         (to_line == from_line && to_char < from_char)
        to_line = from_line
        to_char = from_char
      end
      edit(from_line, from_char, to_line, to_char, replacements.sample(random: rng))
    end

    it "agrees with the whole-document model over 300 successive edits" do
      rng = Random.new(20_260_725)
      text = %(class Sushi\n  MENU = ["🍣", "あじ", "𝔸"]\n  def to_s = "😀"\nend\n)

      300.times do |step|
        change = random_change(text, rng)
        expected = Utf16Reference.splice(text, change[:range], change[:text])
        text = described_class.apply(text, change)
        expect(text).to eq(expected), "diverged at step #{step} on #{change.inspect}"
      end
    end

    it "agrees when the same stream is replayed as one multi-change notification" do
      rng = Random.new(4_242)
      original = %(x = "🍣"\ny = "😀"\nz = 1\n)

      changes = []
      expected = original
      6.times do
        change = random_change(expected, rng)
        expected = Utf16Reference.splice(expected, change[:range], change[:text])
        changes << change
      end

      expect(described_class.apply_all(original, changes)).to eq(expected)
    end
  end

  describe ".utf16_offset_to_index" do
    it "is the identity on an ASCII line" do
      expect(described_class.utf16_offset_to_index("abcdef", 4)).to eq(4)
    end

    it "is the identity on a BMP line" do
      expect(described_class.utf16_offset_to_index("日本語", 2)).to eq(2)
    end

    it "charges two units per non-BMP character" do
      expect(described_class.utf16_offset_to_index("🍣🍣ab", 4)).to eq(2)
      expect(described_class.utf16_offset_to_index("🍣🍣ab", 5)).to eq(3)
    end

    it "clamps past the end of the line" do
      expect(described_class.utf16_offset_to_index("🍣", 99)).to eq(1)
      expect(described_class.utf16_offset_to_index("abc", 99)).to eq(3)
    end
  end
end
