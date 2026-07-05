# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::Singleton do
  describe "construction" do
    it "stores the class_name" do
      s = described_class.new("String")
      expect(s.class_name).to eq("String")
    end

    it "is frozen, including the class_name" do
      s = described_class.new("String")
      expect(s).to be_frozen
      expect(s.class_name).to be_frozen
    end

    it "rejects a non-String class_name" do
      expect { described_class.new(:String) }.to raise_error(ArgumentError, /class_name must be a String/)
    end

    it "rejects an empty class_name" do
      expect { described_class.new("") }.to raise_error(ArgumentError, /must not be empty/)
    end
  end

  describe "describe" do
    it "renders as singleton(ClassName)" do
      expect(described_class.new("String").describe).to eq("singleton(String)")
    end

    it "ignores verbosity" do
      s = described_class.new("String")
      expect(s.describe(:long)).to eq("singleton(String)")
    end
  end

  describe "erase_to_rbs" do
    it "erases to the RBS singleton(ClassName) form" do
      expect(described_class.new("String").erase_to_rbs).to eq("singleton(String)")
    end
  end

  describe "lattice membership" do
    it "answers top / bot / dynamic as no (a plain lattice member)" do
      s = described_class.new("String")
      expect(s.top).to eq(Rigor::Trinary.no)
      expect(s.bot).to eq(Rigor::Trinary.no)
      expect(s.dynamic).to eq(Rigor::Trinary.no)
    end
  end

  describe "value semantics" do
    it "is equal to another Singleton with the same class_name" do
      a = described_class.new("String")
      b = described_class.new("String")
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "differs when class_name differs" do
      expect(described_class.new("String")).not_to eq(described_class.new("Integer"))
    end

    # `Singleton[Foo]` and `Nominal[Foo]` share a class_name but describe disjoint values (the class object vs.
    # instances) — they must never compare equal even though they'd share a value_fields key.
    it "is never equal to a Nominal with the same class_name" do
      singleton = described_class.new("String")
      nominal = Rigor::Type::Nominal.new("String")
      expect(singleton).not_to eq(nominal)
      expect(nominal).not_to eq(singleton)
    end
  end

  describe "inspect" do
    it "includes the class_name" do
      expect(described_class.new("String").inspect).to eq("#<Rigor::Type::Singleton String>")
    end
  end
end
