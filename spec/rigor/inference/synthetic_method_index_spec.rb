# frozen_string_literal: true

require "spec_helper"
require "rigor/inference/synthetic_method_index"

RSpec.describe Rigor::Inference::SyntheticMethodIndex do
  let(:user_avatar) do
    Rigor::Inference::SyntheticMethod.new(
      class_name: "User", method_name: :avatar, return_type: "Object", kind: :instance
    )
  end

  let(:user_with_avatar_scope) do
    Rigor::Inference::SyntheticMethod.new(
      class_name: "User", method_name: :with_attached_avatar, return_type: "Object", kind: :singleton
    )
  end

  describe "construction" do
    it "freezes the index and its entries list" do
      idx = described_class.new(entries: [user_avatar])
      expect(idx).to be_frozen
      expect(idx.entries).to be_frozen
    end

    it "is Ractor.shareable? when its entries are" do
      idx = described_class.new(entries: [user_avatar])
      expect(Ractor.shareable?(idx)).to be(true)
    end

    it "rejects a non-Array entries argument" do
      expect { described_class.new(entries: user_avatar) }.to raise_error(ArgumentError, /entries/)
    end

    it "rejects entries that are not SyntheticMethod" do
      expect { described_class.new(entries: ["nope"]) }.to raise_error(ArgumentError, /entries/)
    end
  end

  describe "lookup_instance / lookup_singleton" do
    let(:idx) { described_class.new(entries: [user_avatar, user_with_avatar_scope]) }

    it "returns the instance match for (class, method)" do
      expect(idx.lookup_instance("User", :avatar)).to eq([user_avatar])
    end

    it "returns the singleton match for (class, method)" do
      expect(idx.lookup_singleton("User", :with_attached_avatar)).to eq([user_with_avatar_scope])
    end

    it "returns an empty array for unmatched (class, method)" do
      expect(idx.lookup_instance("User", :nope)).to eq([])
      expect(idx.lookup_singleton("Other", :avatar)).to eq([])
    end

    it "preserves registration order when multiple entries match the same key" do
      first = Rigor::Inference::SyntheticMethod.new(
        class_name: "User", method_name: :avatar, return_type: "First", kind: :instance
      )
      second = Rigor::Inference::SyntheticMethod.new(
        class_name: "User", method_name: :avatar, return_type: "Second", kind: :instance
      )
      idx = described_class.new(entries: [first, second])
      expect(idx.lookup_instance("User", :avatar)).to eq([first, second])
    end
  end

  describe "EMPTY" do
    it "is empty and frozen" do
      expect(described_class::EMPTY).to be_empty
      expect(described_class::EMPTY).to be_frozen
    end
  end
end
