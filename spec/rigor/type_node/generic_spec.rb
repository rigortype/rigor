# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::TypeNode::Generic do
  let(:address)         { Rigor::TypeNode::Identifier.new(name: "Address") }
  let(:literal_name)    { Rigor::TypeNode::Identifier.new(name: "\"name\"") }
  let(:literal_surname) { Rigor::TypeNode::Identifier.new(name: "\"surname\"") }

  it "stores head and args" do
    node = described_class.new(head: "Pick", args: [address, literal_name])
    expect(node.head).to eq("Pick")
    expect(node.args).to eq([address, literal_name])
  end

  it "freezes the args array to keep the value object immutable" do
    args = [address, literal_name]
    node = described_class.new(head: "Pick", args: args)
    expect(node.args).to be_frozen
  end

  it "accepts a zero-arg Generic (no parser-side size minimum)" do
    node = described_class.new(head: "@empty", args: [])
    expect(node.args).to eq([])
  end

  it "accepts nested Generic args (recursive shape)" do
    keys = described_class.new(head: "Union", args: [literal_name, literal_surname])
    node = described_class.new(head: "Pick", args: [address, keys])
    expect(node.args.last).to be_a(described_class)
    expect(node.args.last.head).to eq("Union")
  end

  it "is Data-class equality: same head + same args compare equal" do
    a = described_class.new(head: "Pick", args: [address, literal_name])
    b = described_class.new(head: "Pick", args: [address, literal_name])
    expect(a).to eq(b)
    expect(a.hash).to eq(b.hash)
  end

  it "rejects a non-String head" do
    expect do
      described_class.new(head: :Pick, args: [address])
    end.to raise_error(ArgumentError, /head must be a non-empty String/)
  end

  it "rejects an empty-String head" do
    expect do
      described_class.new(head: "", args: [address])
    end.to raise_error(ArgumentError, /head must be a non-empty String/)
  end

  it "rejects args that are not an Array" do
    expect do
      described_class.new(head: "Pick", args: address)
    end.to raise_error(ArgumentError, /args must be an Array/)
  end

  it "rejects args whose elements are neither Identifier nor Generic" do
    expect do
      described_class.new(head: "Pick", args: [address, "not-a-node"])
    end.to raise_error(ArgumentError, /args must be an Array of/)
  end
end
