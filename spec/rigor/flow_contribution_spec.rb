# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::FlowContribution do
  describe "construction" do
    it "leaves every content slot at nil by default" do
      contribution = described_class.new
      described_class::SLOT_NAMES.each do |slot|
        expect(contribution.public_send(slot)).to be_nil
      end
    end

    it "freezes the bundle and its collection-shaped slots" do
      contribution = described_class.new(truthy_facts: %i[a b])
      expect(contribution).to be_frozen
      expect(contribution.truthy_facts).to be_frozen
      expect { contribution.truthy_facts << :c }.to raise_error(FrozenError)
    end

    it "defaults the provenance to a builtin Provenance" do
      contribution = described_class.new
      expect(contribution.provenance.source_family).to eq(:builtin)
      expect(contribution.provenance.plugin_id).to be_nil
      expect(contribution.provenance.node).to be_nil
      expect(contribution.provenance.descriptor).to be_nil
    end

    it "accepts a custom provenance" do
      provenance = described_class::Provenance.new(
        source_family: "plugin.rigor-immutable",
        plugin_id: "rigor-immutable",
        node: nil,
        descriptor: nil
      )
      contribution = described_class.new(provenance: provenance)
      expect(contribution.provenance).to equal(provenance)
    end
  end

  describe "#empty?" do
    it "reports true for a default bundle" do
      expect(described_class.new).to be_empty
    end

    it "reports true when collection slots are present but empty" do
      contribution = described_class.new(truthy_facts: [], mutations: [])
      expect(contribution).to be_empty
    end

    it "reports false when any content slot is set" do
      expect(described_class.new(return_type: :Integer)).not_to be_empty
      expect(described_class.new(truthy_facts: [:fact])).not_to be_empty
      expect(described_class.new(exceptional: :raises)).not_to be_empty
    end

    it "ignores the provenance for emptiness" do
      provenance = described_class::Provenance.new(
        source_family: "plugin.x", plugin_id: "x", node: nil, descriptor: nil
      )
      expect(described_class.new(provenance: provenance)).to be_empty
    end
  end

  describe "equality and hashing" do
    it "compares structurally by slot contents" do
      a = described_class.new(return_type: :Integer, truthy_facts: [:t])
      b = described_class.new(return_type: :Integer, truthy_facts: [:t])
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "differs when any slot diverges" do
      base = described_class.new(return_type: :Integer)
      other = described_class.new(return_type: :String)
      expect(base).not_to eq(other)
    end
  end

  describe "#to_h" do
    it "includes every slot plus provenance" do
      contribution = described_class.new(return_type: :Integer, truthy_facts: [:t])
      hash = contribution.to_h
      expect(hash.keys).to contain_exactly(*described_class::SLOT_NAMES, :provenance)
      expect(hash[:return_type]).to eq(:Integer)
      expect(hash[:truthy_facts]).to eq([:t])
      expect(hash[:provenance]).to include(source_family: :builtin)
    end
  end

  describe "#to_element_list" do
    it "flattens a single return-type contribution into one element" do
      contribution = described_class.new(return_type: :Integer)
      elements = contribution.to_element_list

      expect(elements.size).to eq(1)
      expect(elements.first.target).to eq(:return)
      expect(elements.first.edge).to eq(:normal)
      expect(elements.first.kind).to eq(:return_type)
      expect(elements.first.payload).to eq(:Integer)
    end

    it "includes elements for each slot when all are populated" do
      contribution = described_class.new(
        return_type: :Integer, truthy_facts: [:a], falsey_facts: [:b],
        post_return_facts: [:c], mutations: [:m], invalidations: [:i],
        exceptional: :raises, role_conformance: [:r]
      )
      elements = contribution.to_element_list

      expect(elements.size).to be >= 3
      expect(elements.map(&:kind)).to include(:return_type, :truthy_fact, :falsey_fact,
                                              :post_return_fact, :mutation, :invalidation,
                                              :exception, :role)
    end

    it "returns an empty array when the bundle is empty" do
      expect(described_class.new.to_element_list).to eq([])
    end

    it "extracts the target from a payload that responds to #target" do
      payload = Object.new
      payload.define_singleton_method(:target) { :my_target }
      contribution = described_class.new(truthy_facts: [payload])
      element = contribution.to_element_list.first
      expect(element.target).to eq(:my_target)
    end
  end

  describe "Provenance.builtin" do
    it "names the :builtin source family with no plugin id, node, or descriptor" do
      provenance = described_class::Provenance.builtin
      expect(provenance.source_family).to eq(:builtin)
      expect(provenance.plugin_id).to be_nil
      expect(provenance.node).to be_nil
      expect(provenance.descriptor).to be_nil
    end
  end
end
