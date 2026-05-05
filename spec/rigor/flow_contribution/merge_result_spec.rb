# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::FlowContribution::MergeResult do
  it "is empty by default" do
    result = described_class.new
    expect(result).to be_empty
    expect(result).not_to be_conflict
    expect(result.return_type).to be_nil
    expect(result.truthy_facts).to eq([])
    expect(result.provenances).to eq([])
    expect(result.conflicts).to eq([])
  end

  it "freezes its slots after construction" do
    result = described_class.new(
      truthy_facts: ["a"], provenances: [Rigor::FlowContribution::Provenance.builtin]
    )
    expect(result).to be_frozen
    expect(result.truthy_facts).to be_frozen
    expect(result.provenances).to be_frozen
  end

  it "reports conflict? when conflicts are non-empty" do
    conflict = Rigor::FlowContribution::Conflict.new(
      target: :return, edge: :normal, kind: :return_type,
      reason: :return_type_collapse, provenances: [], message: "x"
    )
    result = described_class.new(conflicts: [conflict])
    expect(result).to be_conflict
  end

  describe "#to_h" do
    it "renders every slot plus provenances and conflicts" do
      provenance = Rigor::FlowContribution::Provenance.builtin
      result = described_class.new(
        return_type: "T",
        truthy_facts: ["a"],
        provenances: [provenance]
      )
      h = result.to_h
      expect(h["return_type"]).to eq("T")
      expect(h["truthy_facts"]).to eq(["a"])
      expect(h["provenances"].first[:source_family]).to eq(:builtin)
    end
  end
end
