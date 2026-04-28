# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::HashShape do
  let(:int_nominal) { Rigor::Type::Combinator.nominal_of(Integer) }
  let(:str_nominal) { Rigor::Type::Combinator.nominal_of(String) }

  describe "construction" do
    it "carries the pairs in insertion order" do
      shape = described_class.new(a: int_nominal, b: str_nominal)
      expect(shape.pairs.keys).to eq(%i[a b])
      expect(shape.pairs[:a]).to equal(int_nominal)
      expect(shape.pairs[:b]).to equal(str_nominal)
    end

    it "accepts String keys" do
      shape = described_class.new("a" => int_nominal)
      expect(shape.pairs).to eq({ "a" => int_nominal })
    end

    it "rejects non-Hash inputs" do
      expect { described_class.new(:not_a_hash) }
        .to raise_error(ArgumentError, /pairs must be a Hash/)
    end

    it "rejects keys that are not Symbol or String" do
      expect { described_class.new(1 => int_nominal) }
        .to raise_error(ArgumentError, /HashShape keys must be Symbol or String/)
    end

    it "freezes the pairs hash" do
      shape = described_class.new(a: int_nominal)
      expect(shape.pairs).to be_frozen
    end

    it "freezes the carrier itself" do
      expect(described_class.new({})).to be_frozen
    end
  end

  describe "describe and erase_to_rbs" do
    it "renders the empty shape as {}" do
      shape = described_class.new({})
      expect(shape.describe).to eq("{}")
    end

    it "renders symbol-keyed shapes in RBS record syntax" do
      shape = described_class.new(a: int_nominal, b: str_nominal)
      expect(shape.describe).to eq("{ a: Integer, b: String }")
      expect(shape.erase_to_rbs).to eq("{ a: Integer, b: String }")
    end

    it "renders string-keyed shapes with quoted keys in describe" do
      shape = described_class.new("a" => int_nominal)
      expect(shape.describe).to eq("{ \"a\": Integer }")
    end

    it "erases empty and string-keyed shapes to bare Hash" do
      empty = described_class.new({})
      string_keyed = described_class.new("a" => int_nominal)
      expect(empty.erase_to_rbs).to eq("Hash")
      expect(string_keyed.erase_to_rbs).to eq("Hash")
    end
  end

  describe "structural equality" do
    it "is equal across independent constructions of the same pairs" do
      a = described_class.new(a: int_nominal, b: str_nominal)
      b = described_class.new(a: int_nominal, b: str_nominal)
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "is equal regardless of insertion order (Hash#== semantics)" do
      a = described_class.new(a: int_nominal, b: str_nominal)
      b = described_class.new(b: str_nominal, a: int_nominal)
      expect(a).to eq(b)
    end

    it "is not equal when entries differ" do
      a = described_class.new(a: int_nominal)
      b = described_class.new(a: str_nominal)
      expect(a).not_to eq(b)
    end
  end

  describe "lattice probes" do
    let(:shape) { described_class.new(a: int_nominal) }

    it "answers top/bot/dynamic with Trinary.no" do
      expect(shape.top).to eq(Rigor::Trinary.no)
      expect(shape.bot).to eq(Rigor::Trinary.no)
      expect(shape.dynamic).to eq(Rigor::Trinary.no)
    end
  end

  describe "Combinator.hash_shape_of" do
    it "constructs from a Hash literal" do
      shape = Rigor::Type::Combinator.hash_shape_of(a: int_nominal)
      expect(shape).to be_a(described_class)
      expect(shape.pairs[:a]).to equal(int_nominal)
    end
  end
end
