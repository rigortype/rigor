# frozen_string_literal: true

require "prism"

require "rigor/lens"

RSpec.describe Rigor::Lens::Anchor do
  def anchor_for(source, line)
    result = Prism.parse(source)
    node = result.value.statements.body.find { |statement| statement.location.start_line == line } ||
           result.value.statements.body.first.body.body.find { |statement| statement.location.start_line == line }
    location = node.location
    described_class.new(source, result.comments)
                   .for_span(location.start_offset, location.end_offset, location.start_line, location.end_line)
  end

  def kept(result)
    result.contract_comments.map { |comment| comment.location.slice }
  end

  it "keeps rbs-inline annotations and drops documentation prose" do
    result = anchor_for(<<~RUBY, 4)
      # Adds one.
      # @rbs n: Integer
      #: (Integer) -> Integer
      def succ(n) = n + 1
    RUBY

    expect(kept(result)).to eq(["# @rbs n: Integer", "#: (Integer) -> Integer"])
    expect(result.token).to start_with("2:")
  end

  it "does not let a prose edit above the declaration move the anchor" do
    before = anchor_for("# Old prose.\n#: () -> Integer\ndef one = 1\n", 3)
    after = anchor_for("# New prose, longer.\n#: () -> Integer\ndef one = 1\n", 3)

    expect(after.token).to eq(before.token)
  end

  it "moves the anchor when the contract changes" do
    before = anchor_for("#: () -> Integer\ndef one = 1\n", 2)
    after = anchor_for("#: () -> Numeric\ndef one = 1\n", 2)

    expect(after.token).not_to eq(before.token)
  end

  it "treats an RDoc directive and an indented #: as prose" do
    result = anchor_for("#:nodoc:\n# :call-seq:\ndef one = 1\n", 3)

    expect(kept(result)).to be_empty
    expect(result.token).to start_with("3:")
  end

  it "keeps #[ and @rbs continuation lines" do
    result = anchor_for(<<~RUBY, 5)
      #[Integer]
      # @rbs x: Integer
      #   | String
      # Not a continuation.
      def x(x) = x
    RUBY

    expect(kept(result)).to eq(["#[Integer]", "# @rbs x: Integer", "#   | String"])
  end

  it "ends the run at a blank line" do
    result = anchor_for("#: () -> Integer\n\ndef one = 1\n", 3)

    expect(kept(result)).to be_empty
  end

  it "keeps a trailing #: on the declaration's line" do
    result = anchor_for("class A\n  attr_reader :a #: String\nend\n", 2)

    expect(kept(result)).to eq(["#: String"])
  end

  it "hashes a CRLF file's lines without the carriage return" do
    lf = anchor_for("#: () -> Integer\ndef one = 1\n", 2)
    crlf = anchor_for("#: () -> Integer\r\ndef one = 1\r\n", 2)

    expect(crlf.token).to eq(lf.token)
  end
end
