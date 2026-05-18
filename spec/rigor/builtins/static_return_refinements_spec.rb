# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Builtins::StaticReturnRefinements do
  describe ".lookup" do
    let(:expected_dir_type) do
      Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.non_empty_string,
        Rigor::Type::Combinator.constant_of(nil)
      )
    end

    it "returns `non-empty-string | nil` for Kernel#__dir__ (instance)" do
      type = described_class.lookup(
        owner_class_name: "Kernel",
        method_name: :__dir__,
        kind: :instance
      )
      expect(type).to eq(expected_dir_type)
    end

    it "returns `non-empty-string | nil` for Kernel.__dir__ (singleton)" do
      type = described_class.lookup(
        owner_class_name: "Kernel",
        method_name: :__dir__,
        kind: :singleton
      )
      expect(type).to eq(expected_dir_type)
    end

    it "is nil for an unregistered method name" do
      type = described_class.lookup(
        owner_class_name: "Kernel",
        method_name: :nonexistent,
        kind: :instance
      )
      expect(type).to be_nil
    end

    it "is nil when the owner does not match a registered entry" do
      type = described_class.lookup(
        owner_class_name: "Comparable",
        method_name: :__dir__,
        kind: :instance
      )
      expect(type).to be_nil
    end

    it "is nil when the owner_class_name is nil" do
      type = described_class.lookup(
        owner_class_name: nil,
        method_name: :__dir__,
        kind: :instance
      )
      expect(type).to be_nil
    end
  end

  describe ".owners_for" do
    it "lists Kernel as the owner of __dir__" do
      expect(described_class.owners_for(:__dir__)).to eq(["Kernel"])
    end

    it "returns an empty array for an unregistered method" do
      expect(described_class.owners_for(:nonexistent)).to eq([])
    end

    it "accepts a String method name" do
      expect(described_class.owners_for("__dir__")).to eq(["Kernel"])
    end
  end
end
