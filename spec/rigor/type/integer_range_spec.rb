# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::IntegerRange do
  describe "construction" do
    it "accepts Integer bounds" do
      r = described_class.new(0, 10)
      expect(r.min).to eq(0)
      expect(r.max).to eq(10)
    end

    it "accepts symbolic infinity bounds" do
      r = described_class.new(described_class::NEG_INFINITY, described_class::POS_INFINITY)
      expect(r.universal?).to be(true)
    end

    it "rejects min > max with both concrete" do
      expect { described_class.new(5, 3) }.to raise_error(ArgumentError, /min .* max/)
    end

    it "rejects out-of-order infinities" do
      expect { described_class.new(described_class::POS_INFINITY, 3) }
        .to raise_error(ArgumentError, /bounds out of order/)
      expect { described_class.new(3, described_class::NEG_INFINITY) }
        .to raise_error(ArgumentError, /bounds out of order/)
    end

    it "rejects non-Integer bounds" do
      expect { described_class.new(0.5, 3) }.to raise_error(ArgumentError, /must be Integer/)
    end

    it "freezes the instance" do
      expect(described_class.new(0, 1)).to be_frozen
    end
  end

  describe "describe (named aliases)" do
    it "renders the universal range as 'int'" do
      expect(Rigor::Type::Combinator.universal_int.describe).to eq("int")
    end

    it "renders 1.. as positive-int" do
      expect(Rigor::Type::Combinator.positive_int.describe).to eq("positive-int")
    end

    it "renders 0.. as non-negative-int" do
      expect(Rigor::Type::Combinator.non_negative_int.describe).to eq("non-negative-int")
    end

    it "renders ..-1 as negative-int" do
      expect(Rigor::Type::Combinator.negative_int.describe).to eq("negative-int")
    end

    it "renders ..0 as non-positive-int" do
      expect(Rigor::Type::Combinator.non_positive_int.describe).to eq("non-positive-int")
    end

    it "renders int<a, b> for finite custom ranges" do
      expect(Rigor::Type::Combinator.integer_range(0, 100).describe).to eq("int<0, 100>")
    end

    it "renders int<a, max> and int<min, b> for half-open ranges" do
      expect(Rigor::Type::Combinator.integer_range(5, described_class::POS_INFINITY).describe)
        .to eq("int<5, max>")
      expect(Rigor::Type::Combinator.integer_range(described_class::NEG_INFINITY, 7).describe)
        .to eq("int<min, 7>")
    end
  end

  describe "covers?" do
    it "returns true for ints inside finite bounds" do
      r = described_class.new(0, 10)
      expect(r.covers?(0)).to be(true)
      expect(r.covers?(5)).to be(true)
      expect(r.covers?(10)).to be(true)
    end

    it "returns false for ints outside finite bounds" do
      r = described_class.new(0, 10)
      expect(r.covers?(-1)).to be(false)
      expect(r.covers?(11)).to be(false)
    end

    it "returns false for non-Integer values" do
      expect(described_class.new(0, 10).covers?(5.5)).to be(false)
      expect(described_class.new(0, 10).covers?("5")).to be(false)
    end

    it "lets infinite bounds cover arbitrarily large/small ints" do
      expect(Rigor::Type::Combinator.positive_int.covers?(10**20)).to be(true)
      expect(Rigor::Type::Combinator.negative_int.covers?(-(10**20))).to be(true)
    end
  end

  describe "erase_to_rbs" do
    it "always erases to Integer" do
      expect(Rigor::Type::Combinator.positive_int.erase_to_rbs).to eq("Integer")
      expect(Rigor::Type::Combinator.integer_range(-3, 7).erase_to_rbs).to eq("Integer")
    end
  end

  describe "structural equality" do
    it "treats same-bounds ranges as equal" do
      r1 = described_class.new(1, 10)
      r2 = described_class.new(1, 10)
      expect(r1).to eq(r2)
      expect(r1.hash).to eq(r2.hash)
    end

    it "distinguishes ranges with different bounds" do
      expect(described_class.new(1, 10)).not_to eq(described_class.new(1, 11))
    end
  end

  describe "acceptance" do
    let(:positive) { Rigor::Type::Combinator.positive_int }

    it "accepts a Constant inside the range" do
      result = positive.accepts(Rigor::Type::Combinator.constant_of(5))
      expect(result.yes?).to be(true)
    end

    it "rejects a Constant outside the range" do
      expect(positive.accepts(Rigor::Type::Combinator.constant_of(0)).no?).to be(true)
      expect(positive.accepts(Rigor::Type::Combinator.constant_of(-3)).no?).to be(true)
    end

    it "rejects a non-Integer Constant" do
      expect(positive.accepts(Rigor::Type::Combinator.constant_of("foo")).no?).to be(true)
      expect(positive.accepts(Rigor::Type::Combinator.constant_of(3.14)).no?).to be(true)
    end

    it "accepts a strictly-narrower IntegerRange" do
      narrow = Rigor::Type::Combinator.integer_range(5, 10)
      expect(positive.accepts(narrow).yes?).to be(true)
    end

    it "rejects a wider IntegerRange" do
      expect(positive.accepts(Rigor::Type::Combinator.universal_int).no?).to be(true)
    end

    it "accepts Nominal[Integer] only when the range is universal" do
      universal = Rigor::Type::Combinator.universal_int
      int = Rigor::Type::Combinator.nominal_of("Integer")
      expect(universal.accepts(int).yes?).to be(true)
      expect(positive.accepts(int).no?).to be(true)
    end

    it "is accepted by Nominal[Integer]" do
      int = Rigor::Type::Combinator.nominal_of("Integer")
      expect(int.accepts(positive).yes?).to be(true)
      expect(int.accepts(Rigor::Type::Combinator.integer_range(0, 100)).yes?).to be(true)
    end

    it "is accepted by Nominal[Numeric]" do
      numeric = Rigor::Type::Combinator.nominal_of("Numeric")
      expect(numeric.accepts(Rigor::Type::Combinator.positive_int).yes?).to be(true)
    end

    it "is rejected by unrelated Nominals" do
      str = Rigor::Type::Combinator.nominal_of("String")
      expect(str.accepts(Rigor::Type::Combinator.positive_int).no?).to be(true)
    end
  end
end
