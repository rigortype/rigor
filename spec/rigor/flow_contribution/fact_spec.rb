# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::FlowContribution::Fact do
  let(:string_type) { Rigor::Type::Combinator.nominal_of("String") }

  it "stores target_kind, target_name, type, and negative" do
    fact = described_class.new(target_kind: :parameter, target_name: :s, type: string_type)
    expect(fact.target_kind).to eq(:parameter)
    expect(fact.target_name).to eq(:s)
    expect(fact.type).to eq(string_type)
    expect(fact.negative?).to be(false)
  end

  it "defaults negative to false" do
    fact = described_class.new(target_kind: :parameter, target_name: :s, type: string_type)
    expect(fact.negative?).to be(false)
  end

  it "rejects unknown target_kind values" do
    expect do
      described_class.new(target_kind: :ivar, target_name: :@x, type: string_type)
    end.to raise_error(ArgumentError, /target_kind must be one of/)
  end

  it "rejects non-Symbol target_name values" do
    expect do
      described_class.new(target_kind: :parameter, target_name: "s", type: string_type)
    end.to raise_error(ArgumentError, /target_name must be a Symbol/)
  end

  describe "#target" do
    it "returns :self for self-targeted facts" do
      fact = described_class.new(target_kind: :self, target_name: :self, type: string_type)
      expect(fact.target).to eq(:self)
    end

    it "returns [:parameter, name] for parameter-targeted facts" do
      fact = described_class.new(target_kind: :parameter, target_name: :user, type: string_type)
      expect(fact.target).to eq(%i[parameter user])
    end
  end

  describe "equality" do
    it "treats two facts with the same fields as equal (merge dedup)" do
      a = described_class.new(target_kind: :parameter, target_name: :s, type: string_type)
      b = described_class.new(target_kind: :parameter, target_name: :s, type: string_type)
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "distinguishes positive and negative narrowing as different facts" do
      pos = described_class.new(target_kind: :parameter, target_name: :s, type: string_type)
      neg = described_class.new(target_kind: :parameter, target_name: :s, type: string_type, negative: true)
      expect(pos).not_to eq(neg)
    end
  end

  describe "merger integration" do
    let(:builtin) { Rigor::FlowContribution::Provenance.builtin }

    it "deduplicates equal facts across sources via Fact equality" do
      fact = described_class.new(target_kind: :parameter, target_name: :s, type: string_type)
      lhs = Rigor::FlowContribution.new(truthy_facts: [fact], provenance: builtin)
      rhs = Rigor::FlowContribution.new(
        truthy_facts: [fact],
        provenance: Rigor::FlowContribution::Provenance.new(
          source_family: :rbs_extended, plugin_id: nil, node: nil, descriptor: nil
        )
      )

      result = Rigor::FlowContribution::Merger.merge([lhs, rhs])
      expect(result.truthy_facts.size).to eq(1)
    end

    it "flattens through Element with target keyed on (kind, name)" do
      fact = described_class.new(target_kind: :parameter, target_name: :s, type: string_type)
      bundle = Rigor::FlowContribution.new(truthy_facts: [fact], provenance: builtin)
      element = bundle.to_element_list.first
      expect(element.target).to eq(%i[parameter s])
      expect(element.kind).to eq(:truthy_fact)
    end
  end
end
