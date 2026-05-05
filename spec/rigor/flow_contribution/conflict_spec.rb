# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::FlowContribution::Conflict do
  let(:provenance) { Rigor::FlowContribution::Provenance.builtin }

  it "stores target / edge / kind / reason / provenances / message" do
    conflict = described_class.new(
      target: :return, edge: :normal, kind: :return_type,
      reason: :return_type_collapse,
      provenances: [provenance],
      message: "intersection collapses to bot"
    )

    expect(conflict.target).to eq(:return)
    expect(conflict.edge).to eq(:normal)
    expect(conflict.kind).to eq(:return_type)
    expect(conflict.reason).to eq(:return_type_collapse)
    expect(conflict.provenances).to eq([provenance])
    expect(conflict.message).to eq("intersection collapses to bot")
  end

  it "rejects unknown reasons" do
    expect do
      described_class.new(
        target: :x, edge: :normal, kind: :mutation,
        reason: :bogus, provenances: [], message: ""
      )
    end.to raise_error(ArgumentError, /must be one of/)
  end

  describe "#to_h" do
    it "renders fields including serialised provenances" do
      conflict = described_class.new(
        target: :return, edge: :normal, kind: :return_type,
        reason: :return_type_collapse,
        provenances: [provenance],
        message: "boom"
      )
      h = conflict.to_h
      expect(h["target"]).to eq("return")
      expect(h["reason"]).to eq("return_type_collapse")
      expect(h["sources"].first[:source_family]).to eq(:builtin)
      expect(h["message"]).to eq("boom")
    end
  end
end
