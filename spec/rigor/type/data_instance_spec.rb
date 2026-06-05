# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::DataInstance do
  let(:one) { Rigor::Type::Combinator.constant_of(1) }
  let(:two) { Rigor::Type::Combinator.constant_of("two") }
  let(:members) { { x: one, y: two } }

  describe "construction" do
    it "carries the member -> type map" do
      di = described_class.new(members)
      expect(di.members).to eq(members)
      expect(di.class_name).to be_nil
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
      di = described_class.new(members)
      expect(di.members).to be_frozen
      expect(di).to be_frozen
    end
  end

  describe "member access helpers" do
    it "exposes ordered member names" do
      expect(described_class.new(members).member_names).to eq(%i[x y])
    end

    it "projects a declared member's type" do
      di = described_class.new(members)
      expect(di.member_type(:x)).to eq(one)
      expect(di.member_type(:missing)).to be_nil
    end
  end

  describe "describe and erase_to_rbs" do
    it "renders the anonymous form tagged Data" do
      di = described_class.new(members)
      expect(di.describe).to eq("Data(x: 1, y: \"two\")")
      expect(di.erase_to_rbs).to eq("Data")
    end

    it "renders the named form tagged with the class" do
      di = described_class.new(members, "Point")
      expect(di.describe).to eq("Point(x: 1, y: \"two\")")
      expect(di.erase_to_rbs).to eq("Point")
    end
  end

  describe "capability predicates" do
    it "answers top / bot / dynamic as no" do
      di = described_class.new(members)
      expect(di.top).to eq(Rigor::Trinary.no)
      expect(di.bot).to eq(Rigor::Trinary.no)
      expect(di.dynamic).to eq(Rigor::Trinary.no)
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
    it "constructs through data_instance_of" do
      di = Rigor::Type::Combinator.data_instance_of(members: members, class_name: "Point")
      expect(di).to eq(described_class.new(members, "Point"))
    end
  end
end
