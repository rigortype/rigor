# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::Macro::NestedClassTemplate do
  let(:enum_template) do
    described_class.new(
      receiver_constraint: "Mangrove::Enum",
      block_method: :variants,
      variant_method: :variant,
      symbol_arg_position: 0,
      inner_arg_position: 1,
      inner_reader: :inner
    )
  end

  describe "construction" do
    it "stores the declared fields" do
      t = enum_template
      expect(t.receiver_constraint).to eq("Mangrove::Enum")
      expect(t.block_method).to eq(:variants)
      expect(t.variant_method).to eq(:variant)
      expect(t.symbol_arg_position).to eq(0)
      expect(t.inner_arg_position).to eq(1)
      expect(t.inner_reader).to eq(:inner)
    end

    it "applies sensible defaults" do
      t = described_class.new(receiver_constraint: "My::Enum")
      expect(t.block_method).to eq(:variants)
      expect(t.variant_method).to eq(:variant)
      expect(t.symbol_arg_position).to eq(0)
      expect(t.inner_arg_position).to eq(1)
      expect(t.inner_reader).to eq(:inner)
    end

    it "coerces String method names to Symbols" do
      t = described_class.new(receiver_constraint: "My::Enum", block_method: "cases", inner_reader: "payload")
      expect(t.block_method).to eq(:cases)
      expect(t.inner_reader).to eq(:payload)
    end

    it "freezes the instance" do
      expect(enum_template).to be_frozen
    end
  end

  describe "validation" do
    it "rejects an empty receiver_constraint" do
      expect { described_class.new(receiver_constraint: "") }.to raise_error(ArgumentError, /receiver_constraint/)
    end

    it "rejects a non-String receiver_constraint" do
      expect { described_class.new(receiver_constraint: :sym) }.to raise_error(ArgumentError, /receiver_constraint/)
    end

    it "rejects a negative arg position" do
      expect do
        described_class.new(receiver_constraint: "My::Enum", symbol_arg_position: -1)
      end.to raise_error(ArgumentError, /symbol_arg_position/)
    end

    it "rejects a non-Symbol/String variant_method" do
      expect do
        described_class.new(receiver_constraint: "My::Enum", variant_method: 3)
      end.to raise_error(ArgumentError, /variant_method/)
    end

    it "rejects a non-Symbol/String block_method, naming it" do
      expect do
        described_class.new(receiver_constraint: "My::Enum", block_method: 3)
      end.to raise_error(ArgumentError, /block_method/)
    end

    it "rejects a negative inner_arg_position, naming it" do
      expect do
        described_class.new(receiver_constraint: "My::Enum", inner_arg_position: -1)
      end.to raise_error(ArgumentError, /inner_arg_position/)
    end

    it "rejects a non-Symbol/String inner_reader, naming it" do
      expect do
        described_class.new(receiver_constraint: "My::Enum", inner_reader: 3)
      end.to raise_error(ArgumentError, /inner_reader/)
    end
  end

  describe "value semantics" do
    it "is equal to a structurally identical template" do
      expect(enum_template).to eq(
        described_class.new(
          receiver_constraint: "Mangrove::Enum", block_method: :variants,
          variant_method: :variant, symbol_arg_position: 0, inner_arg_position: 1, inner_reader: :inner
        )
      )
    end

    it "differs when a field differs" do
      expect(enum_template).not_to eq(described_class.new(receiver_constraint: "Other::Enum"))
    end

    it "round-trips through to_h" do
      expect(enum_template.to_h).to eq(
        "receiver_constraint" => "Mangrove::Enum",
        "block_method" => "variants",
        "variant_method" => "variant",
        "symbol_arg_position" => 0,
        "inner_arg_position" => 1,
        "inner_reader" => "inner"
      )
    end

    it "hashes equal for equal templates" do
      expect(enum_template.hash).to eq(described_class.new(receiver_constraint: "Mangrove::Enum").hash)
    end
  end
end
