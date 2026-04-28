# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Trinary do
  describe "flyweights" do
    it "returns the same instance for each value" do
      expect(described_class.yes).to equal(described_class.yes)
      expect(described_class.no).to equal(described_class.no)
      expect(described_class.maybe).to equal(described_class.maybe)
    end

    it "exposes structural equality" do
      expect(described_class.yes).to eq(described_class.yes)
      expect(described_class.yes).not_to eq(described_class.no)
    end

    it "is frozen" do
      expect(described_class.yes).to be_frozen
      expect(described_class.no).to be_frozen
      expect(described_class.maybe).to be_frozen
    end
  end

  describe "boolean predicates" do
    it "answers yes? / no? / maybe?" do
      expect(described_class.yes.yes?).to be true
      expect(described_class.yes.no?).to be false
      expect(described_class.yes.maybe?).to be false

      expect(described_class.no.yes?).to be false
      expect(described_class.no.no?).to be true
      expect(described_class.no.maybe?).to be false

      expect(described_class.maybe.yes?).to be false
      expect(described_class.maybe.no?).to be false
      expect(described_class.maybe.maybe?).to be true
    end
  end

  describe "#negate" do
    it "swaps yes and no, leaves maybe" do
      expect(described_class.yes.negate).to equal(described_class.no)
      expect(described_class.no.negate).to equal(described_class.yes)
      expect(described_class.maybe.negate).to equal(described_class.maybe)
    end
  end

  describe "#and" do
    it "returns no if any operand is no" do
      expect(described_class.no.and(described_class.yes)).to equal(described_class.no)
      expect(described_class.yes.and(described_class.no)).to equal(described_class.no)
      expect(described_class.maybe.and(described_class.no)).to equal(described_class.no)
    end

    it "returns yes only when both are yes" do
      expect(described_class.yes.and(described_class.yes)).to equal(described_class.yes)
    end

    it "returns maybe otherwise" do
      expect(described_class.yes.and(described_class.maybe)).to equal(described_class.maybe)
      expect(described_class.maybe.and(described_class.yes)).to equal(described_class.maybe)
      expect(described_class.maybe.and(described_class.maybe)).to equal(described_class.maybe)
    end
  end

  describe "#or" do
    it "returns yes if any operand is yes" do
      expect(described_class.yes.or(described_class.no)).to equal(described_class.yes)
      expect(described_class.maybe.or(described_class.yes)).to equal(described_class.yes)
    end

    it "returns no only when both are no" do
      expect(described_class.no.or(described_class.no)).to equal(described_class.no)
    end

    it "returns maybe otherwise" do
      expect(described_class.no.or(described_class.maybe)).to equal(described_class.maybe)
      expect(described_class.maybe.or(described_class.maybe)).to equal(described_class.maybe)
    end
  end

  describe ".from_symbol" do
    it "round-trips the three values" do
      expect(described_class.from_symbol(:yes)).to equal(described_class.yes)
      expect(described_class.from_symbol(:no)).to equal(described_class.no)
      expect(described_class.from_symbol(:maybe)).to equal(described_class.maybe)
    end

    it "raises for unknown symbols" do
      expect { described_class.from_symbol(:wat) }.to raise_error(ArgumentError)
    end
  end
end
