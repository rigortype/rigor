# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::Fallback do
  let(:inner_type) { Rigor::Type::Combinator.untyped }

  it "is constructed with all four fields" do
    event = described_class.new(
      node_class: Prism::CallNode,
      location: nil,
      family: :prism,
      inner_type: inner_type
    )

    expect(event.node_class).to eq(Prism::CallNode)
    expect(event.location).to be_nil
    expect(event.family).to eq(:prism)
    expect(event.inner_type).to equal(inner_type)
  end

  it "is frozen by Data.define" do
    event = described_class.new(node_class: Prism::CallNode, location: nil, family: :prism, inner_type: inner_type)
    expect(event).to be_frozen
  end

  it "compares structurally" do
    a = described_class.new(node_class: Prism::CallNode, location: nil, family: :prism, inner_type: inner_type)
    b = described_class.new(node_class: Prism::CallNode, location: nil, family: :prism, inner_type: inner_type)
    expect(a).to eq(b)
    expect(a.hash).to eq(b.hash)
  end

  it "rejects an unknown family" do
    expect do
      described_class.new(node_class: Prism::CallNode, location: nil, family: :unknown, inner_type: inner_type)
    end.to raise_error(ArgumentError)
  end

  it "rejects a non-Class node_class" do
    expect do
      described_class.new(node_class: "CallNode", location: nil, family: :prism, inner_type: inner_type)
    end.to raise_error(ArgumentError)
  end
end
