# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::FlowContribution::Element do
  let(:provenance) { Rigor::FlowContribution::Provenance.builtin }

  it "stores target, edge, kind, payload, and provenance" do
    element = described_class.new(
      target: :return, edge: :normal, kind: :return_type,
      payload: 42, provenance: provenance
    )
    expect(element.target).to eq(:return)
    expect(element.edge).to eq(:normal)
    expect(element.kind).to eq(:return_type)
    expect(element.payload).to eq(42)
    expect(element.provenance).to eq(provenance)
  end

  it "rejects edges outside the canonical set" do
    expect do
      described_class.new(target: :x, edge: :bogus, kind: :return_type,
                          payload: 1, provenance: provenance)
    end.to raise_error(ArgumentError, /edge must be one of/)
  end

  it "rejects kinds outside the canonical set" do
    expect do
      described_class.new(target: :x, edge: :normal, kind: :bogus,
                          payload: 1, provenance: provenance)
    end.to raise_error(ArgumentError, /kind must be one of/)
  end

  describe "#merge_key" do
    it "returns the (target, edge, kind) tuple" do
      element = described_class.new(
        target: :foo, edge: :truthy, kind: :truthy_fact,
        payload: 1, provenance: provenance
      )
      expect(element.merge_key).to eq(%i[foo truthy truthy_fact])
    end
  end
end
