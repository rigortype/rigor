# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::DataClass do
  describe "construction" do
    it "carries the ordered member names" do
      dc = described_class.new(%i[x y])
      expect(dc.members).to eq(%i[x y])
      expect(dc.class_name).to be_nil
    end

    it "carries a class name when supplied" do
      expect(described_class.new(%i[x], "Point").class_name).to eq("Point")
    end

    it "rejects non-Symbol members" do
      expect { described_class.new(["x"]) }.to raise_error(ArgumentError, /Array of Symbols/)
    end

    it "rejects a non-Array members argument" do
      expect { described_class.new(:x) }.to raise_error(ArgumentError, /Array of Symbols/)
    end

    it "rejects an empty class name" do
      expect { described_class.new(%i[x], "") }.to raise_error(ArgumentError, /non-empty String or nil/)
    end

    it "freezes the member list and the carrier" do
      dc = described_class.new(%i[x])
      expect(dc.members).to be_frozen
      expect(dc).to be_frozen
    end
  end

  describe "describe and erase_to_rbs" do
    it "renders the anonymous form as Data.define(...)" do
      dc = described_class.new(%i[x y])
      expect(dc.describe).to eq("Data.define(:x, :y)")
      expect(dc.erase_to_rbs).to eq("singleton(Data)")
    end

    it "renders the named form as singleton(Name)" do
      dc = described_class.new(%i[x], "Point")
      expect(dc.describe).to eq("singleton(Point)")
      expect(dc.erase_to_rbs).to eq("singleton(Point)")
    end
  end

  describe "capability predicates" do
    it "answers top / bot / dynamic as no" do
      dc = described_class.new(%i[x])
      expect(dc.top).to eq(Rigor::Trinary.no)
      expect(dc.bot).to eq(Rigor::Trinary.no)
      expect(dc.dynamic).to eq(Rigor::Trinary.no)
    end
  end

  describe "structural equality" do
    it "is equal across independent constructions of the same shape" do
      a = described_class.new(%i[x y])
      b = described_class.new(%i[x y])
      expect(a).to eq(b)
      expect(a.eql?(b)).to be(true)
      expect(a.hash).to eq(b.hash)
    end

    it "distinguishes member order, member set, and class name" do
      base = described_class.new(%i[x y])
      expect(base).not_to eq(described_class.new(%i[y x]))
      expect(base).not_to eq(described_class.new(%i[x]))
      expect(base).not_to eq(described_class.new(%i[x y], "Point"))
    end
  end

  describe "the Combinator factory" do
    it "constructs through data_class_of" do
      dc = Rigor::Type::Combinator.data_class_of(members: %i[x y], class_name: "Point")
      expect(dc).to eq(described_class.new(%i[x y], "Point"))
    end
  end
end
