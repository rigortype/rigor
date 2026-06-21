# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::StructInstance do
  let(:one) { Rigor::Type::Combinator.constant_of(1) }
  let(:two) { Rigor::Type::Combinator.constant_of("two") }
  let(:members) { { x: one, y: two } }

  describe "construction" do
    it "carries the member -> type map" do
      si = described_class.new(members)
      expect(si.members).to eq(members)
      expect(si.class_name).to be_nil
    end

    it "carries a class name when supplied" do
      expect(described_class.new(members, "Point").class_name).to eq("Point")
    end

    it "rejects non-Symbol keys" do
      expect { described_class.new({ "x" => one }) }.to raise_error(ArgumentError, /Symbol keys/)
    end

    it "rejects a non-Hash members argument" do
      expect { described_class.new([one]) }.to raise_error(ArgumentError, /Symbol keys/)
    end

    it "freezes the member map and the carrier" do
      si = described_class.new(members)
      expect(si.members).to be_frozen
      expect(si).to be_frozen
    end

    it "rejects an invalid class_name" do
      expect { described_class.new(members, "") }.to raise_error(ArgumentError, /non-empty String or nil/)
      expect { described_class.new(members, 123) }.to raise_error(ArgumentError, /non-empty String or nil/)
    end
  end

  describe "member access helpers" do
    it "exposes ordered member names" do
      expect(described_class.new(members).member_names).to eq(%i[x y])
    end

    it "projects a declared member's type" do
      si = described_class.new(members)
      expect(si.member_type(:x)).to eq(one)
      expect(si.member_type(:missing)).to be_nil
    end
  end

  describe "describe and erase_to_rbs" do
    it "renders the anonymous form tagged Struct" do
      si = described_class.new(members)
      expect(si.describe).to eq("Struct(x: 1, y: \"two\")")
      expect(si.erase_to_rbs).to eq("Struct")
    end

    it "renders the named form tagged with the class" do
      si = described_class.new(members, "Point")
      expect(si.describe).to eq("Point(x: 1, y: \"two\")")
      expect(si.erase_to_rbs).to eq("Point")
    end
  end

  describe "capability predicates" do
    it "answers top / bot / dynamic as no" do
      si = described_class.new(members)
      expect(si.top).to eq(Rigor::Trinary.no)
      expect(si.bot).to eq(Rigor::Trinary.no)
      expect(si.dynamic).to eq(Rigor::Trinary.no)
    end
  end

  describe "structural equality" do
    it "is equal across independent constructions of the same shape" do
      a = described_class.new(members, "Point")
      b = described_class.new({ x: one, y: two }, "Point")
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "distinguishes member types and the class tag" do
      base = described_class.new(members)
      expect(base).not_to eq(described_class.new({ x: one, y: one }))
      expect(base).not_to eq(described_class.new(members, "Point"))
    end
  end

  describe "the Combinator factory" do
    it "constructs through struct_instance_of" do
      si = Rigor::Type::Combinator.struct_instance_of(members: members, class_name: "Point")
      expect(si).to eq(described_class.new(members, "Point"))
    end
  end
end
