# frozen_string_literal: true

require "rigor/plugin"

RSpec.describe Rigor::Plugin::AdditionalInitializer do
  describe "def-form (methods:)" do
    it "freezes its fields and normalises method names to symbols" do
      entry = described_class.new(receiver_constraint: "Minitest::Test", methods: %w[setup teardown])
      expect(entry.receiver_constraint).to eq("Minitest::Test")
      expect(entry.methods).to eq(%i[setup teardown])
      expect(entry.block_methods).to eq([])
      expect(entry).to be_frozen
      expect(entry.receiver_constraint).to be_frozen
      expect(entry.methods).to be_frozen
    end

    it "answers covers_method? against the declared method set" do
      entry = described_class.new(receiver_constraint: "Minitest::Test", methods: [:setup])
      expect(entry.covers_method?(:setup)).to be(true)
      expect(entry.covers_method?(:teardown)).to be(false)
    end

    it "answers covers_block_method? as false for a def-form-only entry" do
      entry = described_class.new(receiver_constraint: "Minitest::Test", methods: [:setup])
      expect(entry.covers_block_method?(:setup)).to be(false)
    end

    it "round-trips through #to_h and compares by value" do
      a = described_class.new(receiver_constraint: "Minitest::Test", methods: [:setup])
      b = described_class.new(receiver_constraint: "Minitest::Test", methods: [:setup])
      expect(a.to_h).to eq(
        "receiver_constraint" => "Minitest::Test",
        "methods" => ["setup"],
        "block_methods" => []
      )
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end
  end

  describe "block-form (block_methods:)" do
    it "freezes block_methods and normalises to symbols" do
      entry = described_class.new(
        receiver_constraint: "RSpec::ExampleGroup",
        block_methods: %w[before let subject]
      )
      expect(entry.methods).to eq([])
      expect(entry.block_methods).to eq(%i[before let subject])
      expect(entry).to be_frozen
      expect(entry.block_methods).to be_frozen
    end

    it "answers covers_block_method? against the declared block_methods set" do
      entry = described_class.new(
        receiver_constraint: "RSpec::ExampleGroup",
        block_methods: %i[before let subject]
      )
      expect(entry.covers_block_method?(:before)).to be(true)
      expect(entry.covers_block_method?(:after)).to be(false)
    end

    it "answers covers_method? as false for a block-form-only entry" do
      entry = described_class.new(
        receiver_constraint: "RSpec::ExampleGroup",
        block_methods: [:before]
      )
      expect(entry.covers_method?(:before)).to be(false)
    end

    it "round-trips through #to_h and compares by value" do
      a = described_class.new(
        receiver_constraint: "RSpec::ExampleGroup",
        block_methods: [:before]
      )
      b = described_class.new(
        receiver_constraint: "RSpec::ExampleGroup",
        block_methods: [:before]
      )
      expect(a.to_h).to eq(
        "receiver_constraint" => "RSpec::ExampleGroup",
        "methods" => [],
        "block_methods" => ["before"]
      )
      expect(a).to eq(b)
    end
  end

  describe "combined (methods: + block_methods:)" do
    it "accepts both fields simultaneously" do
      entry = described_class.new(
        receiver_constraint: "MyFramework::Base",
        methods: [:setup],
        block_methods: [:before]
      )
      expect(entry.covers_method?(:setup)).to be(true)
      expect(entry.covers_block_method?(:before)).to be(true)
    end
  end

  describe "validation" do
    it "rejects a blank receiver_constraint" do
      expect do
        described_class.new(receiver_constraint: "", methods: [:setup])
      end.to raise_error(ArgumentError, /receiver_constraint/)
    end

    it "rejects when both methods and block_methods are empty" do
      expect do
        described_class.new(receiver_constraint: "Minitest::Test", methods: [], block_methods: [])
      end.to raise_error(ArgumentError, /methods/)
    end

    it "rejects non-symbol/string method entries in methods:" do
      expect do
        described_class.new(receiver_constraint: "Minitest::Test", methods: [123])
      end.to raise_error(ArgumentError, /methods/)
    end

    it "rejects non-symbol/string entries in block_methods:" do
      expect do
        described_class.new(receiver_constraint: "R", block_methods: [nil])
      end.to raise_error(ArgumentError, /block_methods/)
    end
  end

  it "is Ractor-shareable after construction (ADR-15)" do
    entry = described_class.new(receiver_constraint: "Minitest::Test", methods: [:setup])
    expect(Ractor.shareable?(entry)).to be(true)
  end

  it "is Ractor-shareable for block-form entries (ADR-15)" do
    entry = described_class.new(
      receiver_constraint: "RSpec::ExampleGroup",
      block_methods: [:before]
    )
    expect(Ractor.shareable?(entry)).to be(true)
  end
end
