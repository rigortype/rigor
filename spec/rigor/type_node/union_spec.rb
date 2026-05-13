# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::TypeNode::Union do
  let(:a) { Rigor::TypeNode::Identifier.new(name: "non-empty-string") }
  let(:b) { Rigor::TypeNode::SymbolLiteral.new(value: :name) }
  let(:c) { Rigor::TypeNode::StringLiteral.new(value: "email") }

  it "stores the node list (frozen)" do
    node = described_class.new(nodes: [a, b])
    expect(node.nodes).to eq([a, b])
    expect(node.nodes).to be_frozen
  end

  it "accepts heterogeneous node kinds" do
    expect { described_class.new(nodes: [a, b, c]) }.not_to raise_error
  end

  it "requires at least two nodes" do
    expect { described_class.new(nodes: [a]) }.to raise_error(ArgumentError, /size >= 2/)
  end

  it "rejects non-Array nodes" do
    expect { described_class.new(nodes: a) }.to raise_error(ArgumentError, /must be an Array/)
  end

  it "rejects nodes of unrecognised kinds" do
    expect { described_class.new(nodes: [a, 42]) }.to raise_error(ArgumentError, /TypeNode carriers/)
  end

  it "is Data-class equality across distinct instances" do
    one = described_class.new(nodes: [a, b])
    other = described_class.new(nodes: [a, b])
    expect(one).to eq(other)
  end
end
