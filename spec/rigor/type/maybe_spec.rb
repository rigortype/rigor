# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::Maybe do
  let(:int_type) { Rigor::Type::Combinator.nominal_of(Integer) }
  let(:str_type) { Rigor::Type::Combinator.nominal_of(String) }

  describe "construction" do
    it "carries value_type" do
      maybe = described_class.new(int_type)
      expect(maybe.value_type).to eq(int_type)
    end

    it "rejects nil value_type" do
      expect { described_class.new(nil) }.to raise_error(ArgumentError, /value_type must not be nil/)
    end

    it "freezes itself" do
      expect(described_class.new(int_type)).to be_frozen
    end
  end

  describe "describe and erase_to_rbs" do
    it "describes itself as Maybe[T]" do
      maybe = described_class.new(int_type)
      expect(maybe.describe).to eq("Maybe[Integer]")
    end

    it "erases to Dry::Monads::Maybe[T]" do
      maybe = described_class.new(int_type)
      expect(maybe.erase_to_rbs).to eq("::Dry::Monads::Maybe[Integer]")
    end
  end

  describe "structural equality" do
    it "is equal when value_type matches" do
      m1 = described_class.new(int_type)
      m2 = described_class.new(int_type)
      expect(m1).to eq(m2)
      expect(m1.hash).to eq(m2.hash)
    end

    it "is not equal when value_type differs" do
      m1 = described_class.new(int_type)
      m2 = described_class.new(str_type)
      expect(m1).not_to eq(m2)
    end
  end

  describe "acceptance / subtyping" do
    it "accepts covariant Maybes" do
      super_maybe = described_class.new(Rigor::Type::Combinator.top)
      sub_maybe = described_class.new(int_type)
      expect(super_maybe.accepts(sub_maybe).yes?).to be true
    end

    it "rejects Maybes with incompatible value_type" do
      m1 = described_class.new(int_type)
      m2 = described_class.new(str_type)
      expect(m1.accepts(m2).yes?).to be false
    end

    it "accepts compatible Nominal Maybe" do
      m = described_class.new(int_type)
      nom = Rigor::Type::Combinator.nominal_of("Dry::Monads::Maybe", type_args: [int_type])
      expect(m.accepts(nom).yes?).to be true
    end
  end

  describe "Combinator.maybe_of" do
    it "constructs a Maybe carrier" do
      res = Rigor::Type::Combinator.maybe_of(int_type)
      expect(res).to be_a(described_class)
      expect(res.value_type).to eq(int_type)
    end
  end
end
