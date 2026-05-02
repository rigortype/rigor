# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::Intersection do
  def constant_of(value) = Rigor::Type::Combinator.constant_of(value)
  def nominal_of(name, type_args: []) = Rigor::Type::Combinator.nominal_of(name, type_args: type_args)
  def nes = Rigor::Type::Combinator.non_empty_string
  def lc = Rigor::Type::Combinator.lowercase_string
  def uc = Rigor::Type::Combinator.uppercase_string

  describe "construction through Combinator.intersection" do
    it "wraps two distinct members into an Intersection" do
      type = Rigor::Type::Combinator.intersection(nes, lc)
      expect(type).to be_a(described_class)
      expect(type.members).to contain_exactly(nes, lc)
    end

    it "collapses 0-member intersections to Top" do
      expect(Rigor::Type::Combinator.intersection).to eq(Rigor::Type::Combinator.top)
    end

    it "collapses 1-member intersections to that member" do
      expect(Rigor::Type::Combinator.intersection(nes)).to eq(nes)
    end

    it "drops Top members (Top is the identity)" do
      type = Rigor::Type::Combinator.intersection(nes, Rigor::Type::Combinator.top, lc)
      expect(type.members).to contain_exactly(nes, lc)
    end

    it "collapses to Bot if any member is Bot (Bot is absorbing)" do
      expect(Rigor::Type::Combinator.intersection(nes, Rigor::Type::Combinator.bot))
        .to eq(Rigor::Type::Combinator.bot)
    end

    it "deduplicates structurally-equal members" do
      expect(Rigor::Type::Combinator.intersection(nes, nes, lc).members)
        .to contain_exactly(nes, lc)
    end

    it "flattens nested intersections" do
      inner = described_class.new([nes, lc])
      flat = Rigor::Type::Combinator.intersection(inner, uc)
      expect(flat.members).to contain_exactly(nes, lc, uc)
    end

    it "sorts members canonically so different construction orders compare equal" do
      a = Rigor::Type::Combinator.intersection(nes, lc)
      b = Rigor::Type::Combinator.intersection(lc, nes)
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "is frozen" do
      expect(Rigor::Type::Combinator.intersection(nes, lc).frozen?).to be(true)
    end
  end

  describe "canonical-name display" do
    it "renders non-empty-lowercase-string for non_empty_string ∩ lowercase" do
      expect(Rigor::Type::Combinator.non_empty_lowercase_string.describe)
        .to eq("non-empty-lowercase-string")
    end

    it "renders non-empty-uppercase-string for non_empty_string ∩ uppercase" do
      expect(Rigor::Type::Combinator.non_empty_uppercase_string.describe)
        .to eq("non-empty-uppercase-string")
    end

    it "is order-independent — kebab-case display survives reverse construction order" do
      expect(Rigor::Type::Combinator.intersection(lc, nes).describe)
        .to eq("non-empty-lowercase-string")
    end

    it "falls back to T & U operator form for unrecognised composites" do
      type = described_class.new([nominal_of("Comparable"), nominal_of("Enumerable")])
      expect(type.describe).to eq("Comparable & Enumerable")
    end
  end

  describe "RBS erasure" do
    it "erases to the first member's erasure (same-base composition)" do
      expect(Rigor::Type::Combinator.non_empty_lowercase_string.erase_to_rbs).to eq("String")
      expect(Rigor::Type::Combinator.non_empty_uppercase_string.erase_to_rbs).to eq("String")
    end
  end

  describe "acceptance (conjunction over members)" do
    let(:nels) { Rigor::Type::Combinator.non_empty_lowercase_string }

    it "accepts a Constant String that satisfies every member" do
      expect(nels.accepts(constant_of("hi")).yes?).to be(true)
    end

    it "rejects a Constant String that fails one member (uppercase)" do
      expect(nels.accepts(constant_of("HI")).no?).to be(true)
    end

    it "rejects a Constant String that fails the other member (empty)" do
      expect(nels.accepts(constant_of("")).no?).to be(true)
    end

    it "rejects a Constant of the wrong base type" do
      expect(nels.accepts(constant_of(5)).no?).to be(true)
    end

    it "accepts another Intersection equal to itself" do
      other = Rigor::Type::Combinator.intersection(lc, nes)
      expect(nels.accepts(other).yes?).to be(true)
    end

    it "rejects the bare base nominal because it could fail both members" do
      expect(nels.accepts(nominal_of("String")).no?).to be(true)
    end
  end
end
