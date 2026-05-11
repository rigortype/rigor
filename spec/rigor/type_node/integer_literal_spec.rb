# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::TypeNode::IntegerLiteral do
  it "stores the integer value" do
    node = described_class.new(value: 42)
    expect(node.value).to eq(42)
  end

  it "accepts negative integers" do
    expect(described_class.new(value: -7).value).to eq(-7)
  end

  it "is Data-class equality" do
    a = described_class.new(value: 5)
    b = described_class.new(value: 5)
    expect(a).to eq(b)
  end

  it "rejects non-Integer values" do
    expect do
      described_class.new(value: "5")
    end.to raise_error(ArgumentError, /must be an Integer/)
  end
end
