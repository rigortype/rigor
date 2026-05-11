# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::TypeNode::Identifier do
  it "stores the bare name as supplied by the parser" do
    node = described_class.new(name: "non-empty-string")
    expect(node.name).to eq("non-empty-string")
  end

  it "is Data-class equality: two Identifiers with the same name compare equal" do
    a = described_class.new(name: "Pick")
    b = described_class.new(name: "Pick")
    expect(a).to eq(b)
    expect(a.hash).to eq(b.hash)
  end

  it "rejects a non-String name" do
    expect do
      described_class.new(name: :Pick)
    end.to raise_error(ArgumentError, /must be a non-empty String/)
  end

  it "rejects an empty-String name" do
    expect do
      described_class.new(name: "")
    end.to raise_error(ArgumentError, /must be a non-empty String/)
  end
end
