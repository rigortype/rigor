# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::TypeNode::StringLiteral do
  it "stores the string value" do
    expect(described_class.new(value: "name").value).to eq("name")
  end

  it "is Data-class equality" do
    a = described_class.new(value: "foo")
    b = described_class.new(value: "foo")
    expect(a).to eq(b)
  end

  it "rejects non-String values" do
    expect { described_class.new(value: :name) }.to raise_error(ArgumentError, /must be a String/)
  end
end
