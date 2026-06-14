# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::StructClass do
  describe "construction" do
    it "carries the ordered member names" do
      sc = described_class.new(%i[x y])
      expect(sc.members).to eq(%i[x y])
      expect(sc.class_name).to be_nil
      expect(sc.keyword_init).to be(false)
    end

    it "carries a class name and keyword_init flag when supplied" do
      sc = described_class.new(%i[x], "Point", keyword_init: true)
      expect(sc.class_name).to eq("Point")
      expect(sc.keyword_init).to be(true)
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
      sc = described_class.new(%i[x])
      expect(sc.members).to be_frozen
      expect(sc).to be_frozen
    end
  end

  describe "describe and erase_to_rbs" do
    it "renders the anonymous form as Struct.new(...)" do
      sc = described_class.new(%i[x y])
      expect(sc.describe).to eq("Struct.new(:x, :y)")
      expect(sc.erase_to_rbs).to eq("singleton(Struct)")
    end

    it "renders the named form as singleton(Name)" do
      sc = described_class.new(%i[x], "Point")
      expect(sc.describe).to eq("singleton(Point)")
      expect(sc.erase_to_rbs).to eq("singleton(Point)")
    end
  end

  describe "capability predicates" do
    it "answers top / bot / dynamic as no" do
      sc = described_class.new(%i[x])
      expect(sc.top).to eq(Rigor::Trinary.no)
      expect(sc.bot).to eq(Rigor::Trinary.no)
      expect(sc.dynamic).to eq(Rigor::Trinary.no)
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

    it "distinguishes member order, member set, class name, and keyword_init" do
      base = described_class.new(%i[x y])
      expect(base).not_to eq(described_class.new(%i[y x]))
      expect(base).not_to eq(described_class.new(%i[x]))
      expect(base).not_to eq(described_class.new(%i[x y], "Point"))
      expect(base).not_to eq(described_class.new(%i[x y], nil, keyword_init: true))
    end
  end

  describe "the Combinator factory" do
    it "constructs through struct_class_of" do
      sc = Rigor::Type::Combinator.struct_class_of(members: %i[x y], class_name: "Point", keyword_init: true)
      expect(sc).to eq(described_class.new(%i[x y], "Point", keyword_init: true))
    end
  end
end
