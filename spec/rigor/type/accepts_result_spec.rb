# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::AcceptsResult do
  describe "factories" do
    it "produces yes/no/maybe with the given mode" do
      expect(described_class.yes.trinary).to eq(Rigor::Trinary.yes)
      expect(described_class.no.trinary).to eq(Rigor::Trinary.no)
      expect(described_class.maybe.trinary).to eq(Rigor::Trinary.maybe)
    end

    it "defaults to gradual mode and an empty reasons array" do
      result = described_class.yes
      expect(result.mode).to eq(:gradual)
      expect(result.reasons).to eq([])
    end

    it "accepts an explicit mode" do
      result = described_class.no(mode: :strict)
      expect(result.mode).to eq(:strict)
    end

    it "wraps a single string reason in an array" do
      result = described_class.maybe(reasons: "subtype unresolved")
      expect(result.reasons).to eq(["subtype unresolved"])
    end

    it "rejects unknown modes" do
      expect { described_class.new(Rigor::Trinary.yes, mode: :other) }
        .to raise_error(ArgumentError, /mode must be one of/)
    end

    it "rejects non-Trinary trinary arguments" do
      expect { described_class.new(:yes) }.to raise_error(ArgumentError, /must be Rigor::Trinary/)
    end
  end

  describe "predicates" do
    it "delegates yes?/no?/maybe? to the underlying trinary" do
      expect(described_class.yes).to be_yes
      expect(described_class.no).to be_no
      expect(described_class.maybe).to be_maybe
    end
  end

  describe "#with_reason" do
    it "returns a new result with the reason appended" do
      base = described_class.yes(reasons: ["a"])
      next_result = base.with_reason("b")
      expect(next_result.reasons).to eq(%w[a b])
      expect(base.reasons).to eq(["a"]) # immutable
    end

    it "is a no-op for nil/empty reasons" do
      base = described_class.no
      expect(base.with_reason(nil)).to equal(base)
      expect(base.with_reason("")).to equal(base)
    end
  end

  describe "structural equality" do
    it "treats results with the same trinary, mode, and reasons as equal" do
      a = described_class.yes(reasons: ["r"])
      b = described_class.yes(reasons: ["r"])
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "distinguishes different trinaries" do
      expect(described_class.yes).not_to eq(described_class.maybe)
    end

    it "distinguishes different reason lists" do
      expect(described_class.yes(reasons: ["a"])).not_to eq(described_class.yes(reasons: ["b"]))
    end
  end

  it "is frozen on construction" do
    expect(described_class.yes).to be_frozen
    expect(described_class.yes.reasons).to be_frozen
  end
end
