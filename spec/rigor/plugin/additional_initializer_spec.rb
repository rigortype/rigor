# frozen_string_literal: true

require "rigor/plugin"

RSpec.describe Rigor::Plugin::AdditionalInitializer do
  it "freezes its fields and normalises method names to symbols" do
    entry = described_class.new(receiver_constraint: "Minitest::Test", methods: %w[setup teardown])
    expect(entry.receiver_constraint).to eq("Minitest::Test")
    expect(entry.methods).to eq(%i[setup teardown])
    expect(entry).to be_frozen
    expect(entry.receiver_constraint).to be_frozen
    expect(entry.methods).to be_frozen
  end

  it "answers covers_method? against the declared method set" do
    entry = described_class.new(receiver_constraint: "Minitest::Test", methods: [:setup])
    expect(entry.covers_method?(:setup)).to be(true)
    expect(entry.covers_method?(:teardown)).to be(false)
  end

  it "round-trips through #to_h and compares by value" do
    a = described_class.new(receiver_constraint: "Minitest::Test", methods: [:setup])
    b = described_class.new(receiver_constraint: "Minitest::Test", methods: [:setup])
    expect(a.to_h).to eq("receiver_constraint" => "Minitest::Test", "methods" => ["setup"])
    expect(a).to eq(b)
    expect(a.hash).to eq(b.hash)
  end

  it "rejects a blank receiver_constraint" do
    expect do
      described_class.new(receiver_constraint: "", methods: [:setup])
    end.to raise_error(ArgumentError, /receiver_constraint/)
  end

  it "rejects an empty methods array" do
    expect do
      described_class.new(receiver_constraint: "Minitest::Test", methods: [])
    end.to raise_error(ArgumentError, /methods/)
  end

  it "rejects non-symbol/string method entries" do
    expect do
      described_class.new(receiver_constraint: "Minitest::Test", methods: [123])
    end.to raise_error(ArgumentError, /methods/)
  end

  it "is Ractor-shareable after construction (ADR-15)" do
    entry = described_class.new(receiver_constraint: "Minitest::Test", methods: [:setup])
    expect(Ractor.shareable?(entry)).to be(true)
  end
end
