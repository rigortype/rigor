# frozen_string_literal: true

require "prism"

RSpec.describe Rigor::Source::NodeWalker do
  def parse(source)
    Prism.parse(source).value
  end

  describe ".each" do
    it "yields every Prism node in DFS pre-order" do
      root = parse("1 + 2\n")

      classes = []
      described_class.each(root) { |node| classes << node.class }

      expect(classes).to start_with(Prism::ProgramNode, Prism::StatementsNode, Prism::CallNode)
      expect(classes).to include(Prism::IntegerNode)
      expect(classes.count(Prism::IntegerNode)).to eq(2)
    end

    it "returns an Enumerator when no block is given" do
      root = parse("[1, 2]\n")

      enumerator = described_class.each(root)

      expect(enumerator).to be_a(Enumerator)
      expect(enumerator.to_a).to all(be_a(Prism::Node))
      expect(enumerator.to_a.first).to eq(root)
    end

    it "skips non-Prism children" do
      root = parse(":sym\n")

      visited = described_class.each(root).to_a

      expect(visited).to all(be_a(Prism::Node))
    end

    it "yields the root itself when it has no children" do
      root = parse("nil\n")

      visited = described_class.each(root).to_a

      expect(visited.first).to eq(root)
      expect(visited).to include(an_instance_of(Prism::NilNode))
    end
  end
end
