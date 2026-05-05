# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::FlowContribution, "#to_element_list" do
  let(:provenance) do
    Rigor::FlowContribution::Provenance.new(
      source_family: :rbs_extended, plugin_id: nil, node: nil, descriptor: nil
    )
  end

  it "returns an empty list for an empty bundle" do
    bundle = described_class.new(provenance: provenance)
    expect(bundle.to_element_list).to eq([])
  end

  it "lifts return_type to a single :return / :normal / :return_type element" do
    bundle = described_class.new(return_type: "T", provenance: provenance)
    elements = bundle.to_element_list
    expect(elements.size).to eq(1)
    expect(elements.first.target).to eq(:return)
    expect(elements.first.edge).to eq(:normal)
    expect(elements.first.kind).to eq(:return_type)
    expect(elements.first.payload).to eq("T")
  end

  it "lifts truthy_facts to one element per fact, edge :truthy" do
    bundle = described_class.new(truthy_facts: %w[a b], provenance: provenance)
    elements = bundle.to_element_list
    expect(elements.map(&:edge)).to eq(%i[truthy truthy])
    expect(elements.map(&:kind)).to eq(%i[truthy_fact truthy_fact])
    expect(elements.map(&:payload)).to eq(%w[a b])
  end

  it "lifts exceptional to a single :raise / :exceptional / :exception element" do
    bundle = described_class.new(exceptional: :always_raises, provenance: provenance)
    elements = bundle.to_element_list
    expect(elements.size).to eq(1)
    expect(elements.first.target).to eq(:raise)
    expect(elements.first.edge).to eq(:exceptional)
    expect(elements.first.kind).to eq(:exception)
    expect(elements.first.payload).to eq(:always_raises)
  end

  it "preserves the bundle's provenance on every element" do
    bundle = described_class.new(
      return_type: "T", truthy_facts: ["fact"],
      mutations: ["m"], provenance: provenance
    )
    expect(bundle.to_element_list.map(&:provenance)).to all(eq(provenance))
  end

  it "uses payload#target when available, payload itself otherwise" do
    targeted = Struct.new(:target, :name).new(:obj, "foo")
    bundle = described_class.new(
      truthy_facts: [targeted, "opaque"], provenance: provenance
    )
    elements = bundle.to_element_list
    expect(elements[0].target).to eq(:obj)
    expect(elements[1].target).to eq("opaque")
  end
end
