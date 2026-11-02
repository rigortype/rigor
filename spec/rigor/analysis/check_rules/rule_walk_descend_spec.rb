# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Analysis::CheckRules::RuleWalk, ".descend" do
  def parse(source) = Prism.parse(source).value.statements.body.first

  let(:root) { described_class::Context.root }

  it "hands a child the parent's context when the node changes none of its fields" do
    expect(described_class.descend(parse("foo(1)"), root)).to equal(root)
  end

  it "builds a new context when the node enters a block" do
    entered = described_class.descend(parse("foo { 1 }").block, root)
    expect(entered.in_loop_or_block).to be(true)
  end

  it "builds a new context when the node enters a def" do
    expect(described_class.descend(parse("def m; end"), root).inside_def).to be(true)
  end

  it "extends the qualified prefix on a class node" do
    expect(described_class.descend(parse("class A; end"), root).qualified_prefix).to eq(["A"])
  end

  it "marks the detached ivar facet under a singleton class body" do
    expect(described_class.descend(parse("class << self; end"), root).detached_ivar_facet).to be(true)
  end
end
