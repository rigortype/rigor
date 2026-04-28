# frozen_string_literal: true

require "prism"

RSpec.describe Rigor::Source::NodeLocator do
  def parse(source)
    Prism.parse(source).value
  end

  describe ".at_position" do
    it "returns the deepest expression enclosing the position" do
      source = "x = 1 + 2\n"
      root = parse(source)

      node = described_class.at_position(source: source, root: root, line: 1, column: 5)

      expect(node).to be_a(Prism::IntegerNode)
      expect(node.value).to eq(1)
    end

    it "descends into nested method calls" do
      source = "[1, 2, 3].map { |x| x + 1 }\n"
      root = parse(source)

      block_param = described_class.at_position(source: source, root: root, line: 1, column: 21)

      expect(block_param).to be_a(Prism::LocalVariableReadNode)
      expect(block_param.name).to eq(:x)
    end

    it "returns nil when the position is inside the buffer but outside the AST root" do
      source = "    1\n"
      root = parse(source)

      node = described_class.at_position(source: source, root: root, line: 1, column: 1)

      expect(node).to be_nil
    end

    it "returns the deepest enclosing node for a position inside the AST root" do
      source = "    1\n"
      root = parse(source)

      node = described_class.at_position(source: source, root: root, line: 1, column: 5)

      expect(node).to be_a(Prism::IntegerNode)
    end

    it "raises OutOfRangeError when the line is below 1" do
      source = "1\n"
      root = parse(source)

      expect do
        described_class.at_position(source: source, root: root, line: 0, column: 1)
      end.to raise_error(described_class::OutOfRangeError)
    end

    it "raises OutOfRangeError when the line is past the buffer" do
      source = "1\n"
      root = parse(source)

      expect do
        described_class.at_position(source: source, root: root, line: 5, column: 1)
      end.to raise_error(described_class::OutOfRangeError)
    end

    it "raises OutOfRangeError when the column is below 1" do
      source = "1\n"
      root = parse(source)

      expect do
        described_class.at_position(source: source, root: root, line: 1, column: 0)
      end.to raise_error(described_class::OutOfRangeError)
    end

    it "honors byte offsets when the source contains multibyte characters" do
      source = "x = \"日本語\"\n"
      root = parse(source)

      string_node_offset = source.index("\"")

      node = described_class.at_offset(root: root, offset: string_node_offset + 1)

      expect(node).to be_a(Prism::StringNode)
    end
  end

  describe ".at_offset" do
    it "returns nil when the offset falls outside the AST" do
      source = "1\n"
      root = parse(source)

      node = described_class.at_offset(root: root, offset: 100)

      expect(node).to be_nil
    end
  end

  describe "#position_to_offset" do
    it "translates 1-indexed (line, column) into a 0-indexed byte offset" do
      source = "abc\n  defg\n"
      locator = described_class.new(source: source, root: parse(source))

      expect(locator.position_to_offset(1, 1)).to eq(0)
      expect(locator.position_to_offset(1, 3)).to eq(2)
      expect(locator.position_to_offset(2, 3)).to eq(6) # "abc\n" is 4 bytes; +2 -> column 3 of line 2
    end
  end
end
