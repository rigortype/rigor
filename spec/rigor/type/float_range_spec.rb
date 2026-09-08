# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::FloatRange do
  let(:unit) { described_class.new(0.0, 1.0) }
  let(:half_open) { described_class.new(0.0, 1.0, exclude_end: true) }

  describe "construction" do
    it "accepts Float bounds and the infinities" do
      expect(described_class.new(-Float::INFINITY, Float::INFINITY).min).to eq(-Float::INFINITY)
      expect(described_class.new(0.5, Float::INFINITY).max).to eq(Float::INFINITY)
    end

    it "rejects NaN and non-Float bounds" do
      expect { described_class.new(Float::NAN, 1.0) }.to raise_error(ArgumentError, /non-NaN Float/)
      expect { described_class.new(0, 1.0) }.to raise_error(ArgumentError, /non-NaN Float/)
    end

    it "rejects an empty range, including one emptied by its exclusive end" do
      expect { described_class.new(2.0, 1.0) }.to raise_error(ArgumentError, /empty/)
      expect { described_class.new(1.0, 1.0, exclude_end: true) }.to raise_error(ArgumentError, /empty/)
    end

    it "keeps a single closed point" do
      expect(described_class.new(1.0, 1.0).describe).to eq("Float[1.0..1.0]")
    end

    it "spells a signed zero bound as 0.0" do
      expect(described_class.new(-0.0, 1.0).describe).to eq("Float[0.0..1.0]")
    end
  end

  describe "#covers?" do
    it "follows Range#cover? on the written literal" do
      expect(unit.covers?(0.0)).to be(true)
      expect(unit.covers?(1.0)).to be(true)
      expect(half_open.covers?(1.0)).to be(false)
      expect(half_open.covers?(1.0.prev_float)).to be(true)
      expect(unit.covers?(1.5)).to be(false)
    end

    it "never covers NaN, and covers Infinity only through a closed infinite end" do
      expect(unit.covers?(Float::NAN)).to be(false)
      expect(Rigor::Type::Combinator.non_nan_float.covers?(Float::NAN)).to be(false)
      expect(Rigor::Type::Combinator.non_nan_float.covers?(Float::INFINITY)).to be(true)
      expect(Rigor::Type::Combinator.finite_float.covers?(Float::INFINITY)).to be(false)
      expect(described_class.new(0.0, Float::INFINITY, exclude_end: true).covers?(Float::INFINITY)).to be(false)
      expect(described_class.new(0.0, Float::INFINITY, exclude_end: true).covers?(Float::MAX)).to be(true)
    end

    it "does not cover Integers: the head says Float" do
      expect(unit.covers?(1)).to be(false)
    end
  end

  describe "#describe" do
    it "prints the Ruby range literal after the class" do
      expect(unit.describe).to eq("Float[0.0..1.0]")
      expect(half_open.describe).to eq("Float[0.0...1.0]")
      expect(described_class.new(-2.5, 2.5).describe).to eq("Float[-2.5..2.5]")
    end

    it "drops an infinite bound where Ruby's literal can" do
      expect(described_class.new(0.0, Float::INFINITY).describe).to eq("Float[0.0..]")
      expect(described_class.new(-Float::INFINITY, 1.0).describe).to eq("Float[..1.0]")
      expect(described_class.new(-Float::INFINITY, 1.0, exclude_end: true).describe).to eq("Float[...1.0]")
    end

    it "spells an exclusive infinite end and the extreme finite doubles as constants" do
      expect(described_class.new(0.0, Float::INFINITY, exclude_end: true).describe)
        .to eq("Float[0.0...Float::INFINITY]")
      expect(described_class.new(-Float::MAX, 1.0).describe).to eq("Float[-Float::MAX..1.0]")
      expect(described_class.new(-Float::INFINITY, Float::INFINITY, exclude_end: true).describe)
        .to eq("Float[...Float::INFINITY]")
    end

    it "prefers the named aliases, by the set and not the spelling" do
      expect(Rigor::Type::Combinator.non_nan_float.describe).to eq("non-nan-float")
      expect(Rigor::Type::Combinator.finite_float.describe).to eq("finite-float")
      expect(described_class.new(-Float::MAX, Float::INFINITY, exclude_end: true).describe).to eq("finite-float")
    end

    it "wraps the description in #inspect" do
      expect(unit.inspect).to eq("#<Rigor::Type::FloatRange Float[0.0..1.0]>")
    end
  end

  describe "equality" do
    it "is the set, so an exclusive end equals the closed range up to the previous double" do
      expect(half_open).to eq(described_class.new(0.0, 1.0.prev_float))
      expect(half_open.hash).to eq(described_class.new(0.0, 1.0.prev_float).hash)
      expect(half_open).not_to eq(unit)
    end

    it "treats -0.0 and 0.0 as one bound" do
      expect(described_class.new(-0.0, 1.0)).to eq(unit)
    end

    it "is not equal to an IntegerRange or a Nominal" do
      expect(unit).not_to eq(Rigor::Type::Combinator.integer_range(0, 1))
      expect(unit).not_to eq(Rigor::Type::Combinator.nominal_of("Float"))
    end
  end

  describe "erasure and lattice" do
    it "erases to Float" do
      expect(unit.erase_to_rbs).to eq("Float")
      expect(Rigor::Type::Combinator.non_nan_float.erase_to_rbs).to eq("Float")
    end

    it "is neither top, bot, nor dynamic" do
      expect(unit.top.no?).to be(true)
      expect(unit.bot.no?).to be(true)
      expect(unit.dynamic.no?).to be(true)
    end

    it "is universal only as the non-NaN range" do
      expect(Rigor::Type::Combinator.non_nan_float.universal?).to be(true)
      expect(Rigor::Type::Combinator.finite_float.universal?).to be(false)
    end
  end

  describe "acceptance" do
    it "accepts a covered Float constant and rejects NaN, an outside Float, and an Integer" do
      expect(unit.accepts(Rigor::Type::Combinator.constant_of(0.5)).yes?).to be(true)
      expect(unit.accepts(Rigor::Type::Combinator.constant_of(Float::NAN)).no?).to be(true)
      expect(unit.accepts(Rigor::Type::Combinator.constant_of(1.5)).no?).to be(true)
      expect(unit.accepts(Rigor::Type::Combinator.constant_of(1)).no?).to be(true)
    end

    it "accepts a contained FloatRange on canonical bounds and rejects a wider one" do
      expect(unit.accepts(half_open).yes?).to be(true)
      expect(half_open.accepts(unit).no?).to be(true)
      expect(Rigor::Type::Combinator.non_nan_float.accepts(unit).yes?).to be(true)
      expect(Rigor::Type::Combinator.finite_float.accepts(Rigor::Type::Combinator.non_nan_float).no?).to be(true)
    end

    it "never accepts Nominal[Float], even as the non-NaN range" do
      float = Rigor::Type::Combinator.nominal_of("Float")
      expect(unit.accepts(float).no?).to be(true)
      expect(Rigor::Type::Combinator.non_nan_float.accepts(float).no?).to be(true)
    end

    it "is accepted by Nominal[Float], Numeric and Comparable, and rejected by Integer and String" do
      expect(Rigor::Type::Combinator.nominal_of("Float").accepts(unit).yes?).to be(true)
      expect(Rigor::Type::Combinator.nominal_of("Numeric").accepts(unit).yes?).to be(true)
      expect(Rigor::Type::Combinator.nominal_of("Comparable").accepts(unit).yes?).to be(true)
      expect(Rigor::Type::Combinator.nominal_of("Integer").accepts(unit).no?).to be(true)
      expect(Rigor::Type::Combinator.nominal_of("String").accepts(unit).no?).to be(true)
    end

    it "is rejected by an IntegerRange" do
      expect(Rigor::Type::Combinator.positive_int.accepts(unit).no?).to be(true)
    end
  end
end
