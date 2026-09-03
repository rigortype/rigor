# frozen_string_literal: true

require "spec_helper"
require "rigor/source/constant_path"

RSpec.describe Rigor::Source::ConstantPath do
  def node(source)
    Prism.parse(source).value.statements.body.first
  end

  # A constant path whose base is a runtime expression (`expr::Bar`). Prism models the left side as the dynamic node;
  # the trailing `::Bar` is a ConstantPathNode whose parent is that non-constant node.
  def dynamic_base_path
    node("bar::Baz")
  end

  describe ".qualified_name (lenient)" do
    it "names a single ConstantReadNode" do
      expect(described_class.qualified_name(node("Foo"))).to eq("Foo")
    end

    it "joins a dotted ConstantPathNode" do
      expect(described_class.qualified_name(node("Foo::Bar::Baz"))).to eq("Foo::Bar::Baz")
    end

    it "renders a leading `::` absolute root without the leading colons" do
      expect(described_class.qualified_name(node("::Foo::Bar"))).to eq("Foo::Bar")
    end

    it "drops a dynamic base segment rather than failing" do
      expect(described_class.qualified_name(dynamic_base_path)).to eq("Baz")
    end

    it "returns nil for a node that is not a constant reference" do
      expect(described_class.qualified_name(node("foo"))).to be_nil
      expect(described_class.qualified_name(nil)).to be_nil
    end
  end

  describe ".render (lenient, ConstantPathNode only)" do
    it "renders a dotted path" do
      expect(described_class.render(node("Foo::Bar"))).to eq("Foo::Bar")
    end

    it "renders an absolute root path without leading colons" do
      expect(described_class.render(node("::Foo"))).to eq("Foo")
    end
  end

  describe ".qualified_name_or_nil (strict)" do
    it "agrees with the lenient form on static paths" do
      %w[Foo Foo::Bar A::B::C ::Foo ::A::B].each do |src|
        n = node(src)
        expect(described_class.qualified_name_or_nil(n))
          .to eq(described_class.qualified_name(n)), "mismatch on #{src.inspect}"
      end
    end

    it "yields nil for a dynamic base rather than a partial name" do
      expect(described_class.qualified_name_or_nil(dynamic_base_path)).to be_nil
    end

    it "returns nil for a node that is not a constant reference" do
      expect(described_class.qualified_name_or_nil(node("foo"))).to be_nil
      expect(described_class.qualified_name_or_nil(nil)).to be_nil
    end
  end

  # #614 — the rendered name is un-rooted on purpose (the discovery tables are keyed that way), so the
  # leading `::` has to travel out of band. Prism spells the root as a nil `parent` at the LEFTMOST
  # segment, which is why the predicate walks rather than inspecting the outermost node.
  describe ".rooted?" do
    it "reports a leading `::` on a single-segment reference" do
      expect(described_class.rooted?(node("::Foo"))).to be(true)
    end

    it "reports a leading `::` through every segment of a multi-segment path" do
      path = node("::Foo::Bar::Baz")
      expect(described_class.rooted?(path)).to be(true)
      expect(described_class.rooted?(path.parent)).to be(true)
    end

    it "is false for a relative path and for a bare constant read" do
      expect(described_class.rooted?(node("Foo::Bar"))).to be(false)
      expect(described_class.rooted?(node("Foo"))).to be(false)
    end

    it "is false for a dynamic base and for a non-constant node" do
      expect(described_class.rooted?(dynamic_base_path)).to be(false)
      expect(described_class.rooted?(node("foo"))).to be(false)
      expect(described_class.rooted?(nil)).to be(false)
    end
  end

  # #708 — the two header readings, which differ in exactly one place: the class's own NAME resets on a
  # rooted header while its `Module.nesting` keeps the enclosing entries beneath the reset one. Both are
  # given the header node so they can consult `.rooted?`, which the rendered name has already dropped.
  describe ".declaration_prefix" do
    def header(source)
      node(source).constant_path
    end

    it "appends a relative header to the prefix it is written under" do
      expect(described_class.declaration_prefix(%w[Outer], header("class Bar; end"))).to eq(%w[Outer Bar])
    end

    it "keeps a compact relative header as ONE entry" do
      expect(described_class.declaration_prefix([], header("class Admin::Widget; end"))).to eq(["Admin::Widget"])
    end

    it "drops the enclosing prefix for a rooted header" do
      expect(described_class.declaration_prefix(%w[Outer], header("class ::Rooted::Bar; end")))
        .to eq(["Rooted::Bar"])
    end

    it "drops it for the single-segment rooted header too (#638)" do
      expect(described_class.declaration_prefix(%w[MyApp], header("class ::Foo; end"))).to eq(%w[Foo])
    end

    it "leaves the caller's prefix alone when the header names no constant" do
      expect(described_class.declaration_prefix(%w[Outer], node("foo"))).to be_nil
    end
  end

  describe ".pushed_nesting" do
    def header(source)
      node(source).constant_path
    end

    it "qualifies a relative header against the entry already on top" do
      expect(described_class.pushed_nesting(["Outer"], header("class Bar; end"))).to eq(["Outer::Bar", "Outer"])
    end

    it "pushes ONE entry for a compact header" do
      expect(described_class.pushed_nesting([], header("class Admin::Widget; end"))).to eq(["Admin::Widget"])
    end

    # The half that is NOT a reset: Ruby's nesting inside `class ::Rooted::Bar` written in `module Outer`
    # is `[Rooted::Bar, Outer]`, so the enclosing rung stays live even though the name reset.
    it "pushes a rooted header un-prefixed and keeps the enclosing entries beneath it" do
      expect(described_class.pushed_nesting(["Outer"], header("class ::Rooted::Bar; end")))
        .to eq(["Rooted::Bar", "Outer"])
    end

    it "renders `class self::Thing` as Ruby's own answer rather than refusing it" do
      expect(described_class.pushed_nesting(["Outer"], header("class self::Thing; end")))
        .to eq(["Outer::Thing", "Outer"])
    end

    it "propagates a nil chain" do
      expect(described_class.pushed_nesting(nil, header("class Bar; end"))).to be_nil
    end
  end
end
