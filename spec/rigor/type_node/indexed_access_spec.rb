# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::TypeNode::IndexedAccess do
  let(:tuple_ast) do
    Rigor::TypeNode::Generic.new(
      head: "Tuple",
      args: [
        Rigor::TypeNode::Identifier.new(name: "String"),
        Rigor::TypeNode::Identifier.new(name: "Integer")
      ]
    )
  end
  let(:zero_key) { Rigor::TypeNode::IntegerLiteral.new(value: 0) }

  it "stores receiver and key" do
    node = described_class.new(receiver: tuple_ast, key: zero_key)
    expect(node.receiver).to eq(tuple_ast)
    expect(node.key).to eq(zero_key)
  end

  it "accepts nested IndexedAccess in the receiver slot" do
    inner = described_class.new(receiver: tuple_ast, key: zero_key)
    outer = described_class.new(receiver: inner, key: zero_key)
    expect(outer.receiver).to eq(inner)
  end

  it "is Data-class equality" do
    a = described_class.new(receiver: tuple_ast, key: zero_key)
    b = described_class.new(receiver: tuple_ast, key: zero_key)
    expect(a).to eq(b)
  end

  it "rejects a receiver that is not a TypeNode" do
    expect do
      described_class.new(receiver: "Tuple", key: zero_key)
    end.to raise_error(ArgumentError, /receiver must be a TypeNode/)
  end

  it "rejects a key that is not a TypeNode" do
    expect do
      described_class.new(receiver: tuple_ast, key: 0)
    end.to raise_error(ArgumentError, /key must be a TypeNode/)
  end
end
