# frozen_string_literal: true

require "spec_helper"
require "rigor/inference/synthetic_method"

RSpec.describe Rigor::Inference::SyntheticMethod do
  describe "construction" do
    it "stores the declared fields and freezes the value" do
      sm = described_class.new(
        class_name: "User",
        method_name: :avatar,
        return_type: "ActiveStorage::Attached::One",
        kind: :instance,
        provenance: { plugin_id: "activestorage", template_method: "has_one_attached" }
      )
      expect(sm.class_name).to eq("User")
      expect(sm.method_name).to eq(:avatar)
      expect(sm.return_type).to eq("ActiveStorage::Attached::One")
      expect(sm.kind).to eq(:instance)
      expect(sm.provenance[:plugin_id]).to eq("activestorage")
      expect(sm).to be_frozen
    end

    it "defaults kind to :instance and provenance to empty Hash" do
      sm = described_class.new(class_name: "X", method_name: :y, return_type: "Z")
      expect(sm.kind).to eq(:instance)
      expect(sm.provenance).to eq({})
    end

    it "is Ractor.shareable?" do
      sm = described_class.new(class_name: "X", method_name: :y, return_type: "Z")
      expect(Ractor.shareable?(sm)).to be(true)
    end

    it "exposes instance? / singleton? predicates" do
      i = described_class.new(class_name: "X", method_name: :y, return_type: "Z", kind: :instance)
      s = described_class.new(class_name: "X", method_name: :y, return_type: "Z", kind: :singleton)
      expect(i.instance?).to be(true)
      expect(i.singleton?).to be(false)
      expect(s.singleton?).to be(true)
      expect(s.instance?).to be(false)
    end
  end

  describe "validation" do
    it "rejects an empty class_name" do
      expect do
        described_class.new(class_name: "", method_name: :y, return_type: "Z")
      end.to raise_error(ArgumentError, /class_name/)
    end

    it "rejects an empty return_type" do
      expect do
        described_class.new(class_name: "X", method_name: :y, return_type: "")
      end.to raise_error(ArgumentError, /return_type/)
    end

    it "rejects a kind outside the valid set" do
      expect do
        described_class.new(class_name: "X", method_name: :y, return_type: "Z", kind: :class)
      end.to raise_error(ArgumentError, /kind/)
    end
  end

  describe "equality + #to_h" do
    it "treats records with equal fields as equal and renders a stable Hash" do
      a = described_class.new(class_name: "X", method_name: :y, return_type: "Z")
      b = described_class.new(class_name: "X", method_name: :y, return_type: "Z")
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
      expect(a.to_h["class_name"]).to eq("X")
      expect(a.to_h["method_name"]).to eq("y")
      expect(a.to_h["return_type"]).to eq("Z")
      expect(a.to_h["kind"]).to eq("instance")
    end
  end
end
