# frozen_string_literal: true

require "spec_helper"
require "rigor/cli/prism_colorizer"

RSpec.describe Rigor::CLI::PrismColorizer do
  def colorize(source)
    described_class.colorize(source)
  end

  it "leaves the visible text unchanged when the escapes are stripped" do
    source = "a = 1  # note\n"
    stripped = colorize(source).gsub(/\e\[[0-9;]*m/, "")

    expect(stripped).to eq(source)
  end

  it "paints an integer literal" do
    expect(colorize("42\n")).to include("\e[34m42\e[0m")
  end

  it "paints a comment in faint grey" do
    expect(colorize("# hello\n")).to include("\e[90m# hello\e[0m")
  end

  it "paints a keyword" do
    expect(colorize("if x\nend\n")).to include("\e[33mif\e[0m")
  end

  it "paints `nil` as a literal keyword, not an ordinary keyword" do
    expect(colorize("nil\n")).to include("\e[36mnil\e[0m")
  end

  it "paints the whole symbol — including a keyword-shaped name — in one colour" do
    # `:then` lexes as SYMBOL_BEGIN + KEYWORD_THEN; both halves must carry the symbol colour, never the keyword colour.
    colored = colorize(":then\n")

    expect(colored).to include("\e[36m:\e[0m\e[36mthen\e[0m")
    expect(colored).not_to include("\e[33mthen")
  end

  it "keeps a trailing newline outside the colour span" do
    # The comment token includes its newline; the reset must sit before it so the escape does not bleed onto the next
    # line.
    expect(colorize("# c\n")).to end_with("\e[0m\n")
  end

  it "returns the source unchanged when lexing surfaces an error" do
    source = "def broken(\n"

    expect(colorize(source)).to eq(source)
  end

  it "retags a US-ASCII-labelled source carrying UTF-8 bytes before lexing" do
    # Sources read under a POSIX locale arrive tagged US-ASCII; the colorizer dups and retags to UTF-8 so the token
    # regexes do not raise on the multibyte comment.
    source = "x = 1  # コメント\n".dup.force_encoding(Encoding::US_ASCII)
    stripped = colorize(source).gsub(/\e\[[0-9;]*m/, "")

    expect(stripped).to include("コメント")
    # The retag works on a dup — the caller's string is not mutated.
    expect(source.encoding).to eq(Encoding::US_ASCII)
  end
end
