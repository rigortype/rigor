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

  describe "#to_diagnostic (v0.1.0 slice 5-C)" do
    let(:conflict) do
      described_class.new(
        target: :return, edge: :normal, kind: :return_type,
        reason: :return_type_collapse,
        provenances: [provenance],
        message: "intersection collapses"
      )
    end

    it "produces a Diagnostic with source_family :contribution_merge" do
      diagnostic = conflict.to_diagnostic(path: "f.rb", line: 3, column: 5)
      expect(diagnostic).to be_a(Rigor::Analysis::Diagnostic)
      expect(diagnostic.source_family).to eq(:contribution_merge)
      expect(diagnostic.rule).to eq("return-type-collapse")
      expect(diagnostic.message).to eq("intersection collapses")
      expect(diagnostic.path).to eq("f.rb")
      expect(diagnostic.line).to eq(3)
      expect(diagnostic.column).to eq(5)
    end

    it "kebab-cases multi-word reasons in the rule identifier" do
      lower = described_class.new(
        target: :return, edge: :normal, kind: :return_type,
        reason: :lower_tier_contradiction,
        provenances: [provenance],
        message: "lower tier contradicts"
      )
      expect(lower.to_diagnostic(path: "f.rb", line: 1, column: 1).rule).to eq("lower-tier-contradiction")
    end

    it "renders qualified rule via Diagnostic#to_s" do
      text = conflict.to_diagnostic(path: "f.rb", line: 3, column: 5).to_s
      expect(text).to include("[contribution_merge.return-type-collapse]")
    end

    it "accepts an explicit severity override" do
      diagnostic = conflict.to_diagnostic(path: "f.rb", line: 1, column: 1, severity: :warning)
      expect(diagnostic.severity).to eq(:warning)
    end
  end
end
