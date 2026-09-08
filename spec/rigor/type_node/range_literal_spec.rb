# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::TypeNode::RangeLiteral do
  it "stores the range value" do
    node = described_class.new(value: 1..10)
    expect(node.value).to eq(1..10)
  end

  it "keeps exclusive ends and open endpoints as Ruby spells them" do
    expect(described_class.new(value: 1...10).value.exclude_end?).to be(true)
    expect(described_class.new(value: (1..)).value.end).to be_nil
    expect(described_class.new(value: (..10)).value.begin).to be_nil
  end

  it "is Data-class equality" do
    closed = described_class.new(value: 1..10)
    same = described_class.new(value: 1..10)
    exclusive = described_class.new(value: 1...10)
    expect(closed).to eq(same)
    expect(closed).not_to eq(exclusive)
  end

  it "rejects non-Range values" do
    expect do
      described_class.new(value: "1..10")
    end.to raise_error(ArgumentError, /must be a Range/)
  end
end
