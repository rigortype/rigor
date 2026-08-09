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

    # Issue #318 — `defined?`'s operand is never evaluated at runtime, so the walk must yield the
    # `DefinedNode` itself (its presence is real source) but must NOT descend into `#value`: nothing under
    # it is reachable, evaluated code.
    it "yields a DefinedNode but does not descend into its operand" do
      root = parse("defined?(@subject && @subject.options.empty?)\n")

      visited = described_class.each(root).to_a

      expect(visited).to include(an_instance_of(Prism::DefinedNode))
      expect(visited).not_to include(an_instance_of(Prism::CallNode))
      expect(visited).not_to include(an_instance_of(Prism::InstanceVariableReadNode))
    end
  end

  describe ".each_with_ancestors" do
    it "yields each node alongside its lexical ancestor chain" do
      root = parse("class Foo; def bar; 1 + 2; end; end\n")

      pairs = []
      described_class.each_with_ancestors(root) { |node, ancestors| pairs << [node.class, ancestors.size] }

      expect(pairs).to include([Prism::IntegerNode, a_value >= 3]) # deeply nested
    end

    it "returns an Enumerator when no block is given" do
      root = parse("x = 1\n")

      enumerator = described_class.each_with_ancestors(root)

      expect(enumerator).to be_a(Enumerator)
    end

    it "skips non-Prism children" do
      root = parse(":sym\n")

      visited = described_class.each_with_ancestors(root).to_a

      expect(visited).to all(be_a(Array))
      expect(visited.map(&:first)).to all(be_a(Prism::Node))
    end

    it "tracks the ancestor chain correctly through nested nodes" do
      root = parse("1 + 2\n")

      integer_nodes = []
      described_class.each_with_ancestors(root) do |node, ancestors|
        integer_nodes << [node, ancestors.dup] if node.is_a?(Prism::IntegerNode)
      end

      expect(integer_nodes.size).to eq(2)
      # Each IntegerNode's ancestors should include the CallNode
      expect(integer_nodes.map { |_, a| a.map(&:class) }).to all(include(Prism::CallNode))
    end

    # Issue #318 — same non-descent contract as `.each`.
    it "yields a DefinedNode but does not descend into its operand" do
      root = parse("defined?(@subject && @subject.options.empty?)\n")

      visited = described_class.each_with_ancestors(root).to_a

      expect(visited.map(&:first)).to include(an_instance_of(Prism::DefinedNode))
      expect(visited.map(&:first)).not_to include(an_instance_of(Prism::CallNode))
      expect(visited.map(&:first)).not_to include(an_instance_of(Prism::InstanceVariableReadNode))
    end
  end
end
