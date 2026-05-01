# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::Tuple do
  let(:int_nominal) { Rigor::Type::Combinator.nominal_of(Integer) }
  let(:str_nominal) { Rigor::Type::Combinator.nominal_of(String) }

  describe "construction" do
    it "carries the elements in order" do
      t = described_class.new([int_nominal, str_nominal])
      expect(t.elements).to eq([int_nominal, str_nominal])
    end

    it "rejects non-Array inputs" do
      expect { described_class.new(:not_an_array) }
        .to raise_error(ArgumentError, /elements must be an Array/)
    end

    it "freezes the elements list" do
      t = described_class.new([int_nominal])
      expect(t.elements).to be_frozen
    end

    it "freezes the carrier itself" do
      expect(described_class.new([])).to be_frozen
    end
  end

  describe "describe and erase_to_rbs" do
    it "renders the empty Tuple as []" do
      t = described_class.new([])
      expect(t.describe).to eq("[]")
      expect(t.erase_to_rbs).to eq("[]")
    end

    it "renders a non-empty Tuple as [A, B, ...]" do
      t = described_class.new([int_nominal, str_nominal])
      expect(t.describe).to eq("[Integer, String]")
      expect(t.erase_to_rbs).to eq("[Integer, String]")
    end
  end

  describe "structural equality" do
    it "is equal across independent constructions of the same elements" do
      a = described_class.new([int_nominal, str_nominal])
      b = described_class.new([int_nominal, str_nominal])
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "is not equal for different element orders" do
      a = described_class.new([int_nominal, str_nominal])
      b = described_class.new([str_nominal, int_nominal])
      expect(a).not_to eq(b)
    end
  end

  describe "lattice probes" do
    let(:t) { described_class.new([int_nominal]) }

    it "answers top/bot/dynamic with Trinary.no" do
      expect(t.top).to eq(Rigor::Trinary.no)
      expect(t.bot).to eq(Rigor::Trinary.no)
      expect(t.dynamic).to eq(Rigor::Trinary.no)
    end
  end

  describe "Combinator.tuple_of" do
    it "constructs from positional element types" do
      t = Rigor::Type::Combinator.tuple_of(int_nominal, str_nominal)
      expect(t).to be_a(described_class)
      expect(t.elements).to eq([int_nominal, str_nominal])
    end

    it "produces an empty Tuple from no arguments" do
      t = Rigor::Type::Combinator.tuple_of
      expect(t.elements).to eq([])
      expect(t.describe).to eq("[]")
    end
  end
end
