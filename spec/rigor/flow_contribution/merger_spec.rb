# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::FlowContribution::Merger do
  let(:builtin) { Rigor::FlowContribution::Provenance.builtin }
  let(:rbs_extended) do
    Rigor::FlowContribution::Provenance.new(
      source_family: :rbs_extended, plugin_id: nil, node: nil, descriptor: nil
    )
  end
  let(:plugin_alpha) do
    Rigor::FlowContribution::Provenance.new(
      source_family: :plugin, plugin_id: "alpha", node: nil, descriptor: nil
    )
  end
  let(:plugin_beta) do
    Rigor::FlowContribution::Provenance.new(
      source_family: :plugin, plugin_id: "beta", node: nil, descriptor: nil
    )
  end

  describe ".tier_for" do
    it "maps :builtin to tier 0" do
      expect(described_class.tier_for(builtin)).to eq(0)
    end

    it "maps :rbs_extended and :generated to tier 1" do
      expect(described_class.tier_for(rbs_extended)).to eq(1)
    end

    it "maps :plugin and plugin.<id> to tier 2" do
      expect(described_class.tier_for(plugin_alpha)).to eq(2)
      qualified = Rigor::FlowContribution::Provenance.new(
        source_family: "plugin.foo", plugin_id: "foo", node: nil, descriptor: nil
      )
      expect(described_class.tier_for(qualified)).to eq(2)
    end

    it "maps unknown families to tier 3" do
      unknown = Rigor::FlowContribution::Provenance.new(
        source_family: :something_else, plugin_id: nil, node: nil, descriptor: nil
      )
      expect(described_class.tier_for(unknown)).to eq(3)
    end
  end

  describe ".merge" do
    it "returns an empty result for an empty input" do
      expect(described_class.merge([])).to be_empty
    end

    it "passes through a single contribution unchanged" do
      contribution = Rigor::FlowContribution.new(
        return_type: "T", truthy_facts: %w[a b],
        mutations: ["m"], provenance: builtin
      )
      result = described_class.merge([contribution])

      expect(result.return_type).to eq("T")
      expect(result.truthy_facts).to eq(%w[a b])
      expect(result.mutations).to eq(["m"])
      expect(result.provenances).to eq([builtin])
      expect(result).not_to be_conflict
    end

    it "intersects compatible return types" do
      lhs = Rigor::FlowContribution.new(
        return_type: Rigor::Type::Combinator.nominal_of("Object"),
        provenance: builtin
      )
      rhs = Rigor::FlowContribution.new(
        return_type: Rigor::Type::Combinator.nominal_of("Object"),
        provenance: rbs_extended
      )
      result = described_class.merge([lhs, rhs])

      expect(result).not_to be_conflict
      expect(result.return_type).not_to be_nil
    end

    it "reports a return-type collapse when the intersection is bot" do
      string_type = Rigor::Type::Combinator.nominal_of("String")
      integer_type = Rigor::Type::Combinator.nominal_of("Integer")

      lhs = Rigor::FlowContribution.new(return_type: string_type, provenance: plugin_alpha)
      rhs = Rigor::FlowContribution.new(return_type: integer_type, provenance: plugin_beta)
      result = described_class.merge([lhs, rhs])

      expect(result).to be_conflict
      conflict = result.conflicts.first
      expect(conflict.kind).to eq(:return_type)
      expect(conflict.reason).to eq(:return_type_collapse)
      expect(conflict.provenances).to include(plugin_alpha, plugin_beta)
    end

    it "flags a lower-tier contradiction when a plugin disagrees with builtin" do
      string_type = Rigor::Type::Combinator.nominal_of("String")
      integer_type = Rigor::Type::Combinator.nominal_of("Integer")

      builtin_contribution = Rigor::FlowContribution.new(
        return_type: string_type, provenance: builtin
      )
      plugin_contribution = Rigor::FlowContribution.new(
        return_type: integer_type, provenance: plugin_alpha
      )
      result = described_class.merge([builtin_contribution, plugin_contribution])

      expect(result).to be_conflict
      expect(result.conflicts.first.reason).to eq(:lower_tier_contradiction)
      expect(result.return_type).to eq(string_type)
    end

    it "accumulates and dedupes truthy / falsey / post_return facts" do
      lhs = Rigor::FlowContribution.new(
        truthy_facts: %w[a b], post_return_facts: ["x"],
        provenance: builtin
      )
      rhs = Rigor::FlowContribution.new(
        truthy_facts: %w[b c], post_return_facts: ["x"],
        provenance: plugin_alpha
      )
      result = described_class.merge([lhs, rhs])

      expect(result.truthy_facts).to eq(%w[a b c])
      expect(result.post_return_facts).to eq(["x"])
    end

    it "unions mutations / invalidations / role_conformance" do
      lhs = Rigor::FlowContribution.new(
        mutations: %w[m1], invalidations: ["i1"], role_conformance: ["r1"],
        provenance: rbs_extended
      )
      rhs = Rigor::FlowContribution.new(
        mutations: %w[m1 m2], invalidations: ["i2"], role_conformance: ["r2"],
        provenance: plugin_alpha
      )
      result = described_class.merge([lhs, rhs])

      expect(result.mutations).to eq(%w[m1 m2])
      expect(result.invalidations).to eq(%w[i1 i2])
      expect(result.role_conformance).to eq(%w[r1 r2])
    end

    it "treats matching exceptional effects as compatible" do
      lhs = Rigor::FlowContribution.new(exceptional: :always_raises, provenance: builtin)
      rhs = Rigor::FlowContribution.new(exceptional: :always_raises, provenance: plugin_alpha)
      result = described_class.merge([lhs, rhs])

      expect(result).not_to be_conflict
      expect(result.exceptional).to eq(:always_raises)
    end

    it "flags exceptional disagreement at the same tier" do
      lhs = Rigor::FlowContribution.new(exceptional: :always_raises, provenance: plugin_alpha)
      rhs = Rigor::FlowContribution.new(exceptional: :never_returns, provenance: plugin_beta)
      result = described_class.merge([lhs, rhs])

      expect(result).to be_conflict
      conflict = result.conflicts.first
      expect(conflict.kind).to eq(:exception)
      expect(conflict.reason).to eq(:exceptional_disagreement)
    end

    it "orders contributions by tier, then plugin id, then input position" do
      contribs = [
        Rigor::FlowContribution.new(truthy_facts: ["plugin_beta"], provenance: plugin_beta),
        Rigor::FlowContribution.new(truthy_facts: ["plugin_alpha"], provenance: plugin_alpha),
        Rigor::FlowContribution.new(truthy_facts: ["builtin"], provenance: builtin)
      ]
      result = described_class.merge(contribs)
      expect(result.truthy_facts).to eq(%w[builtin plugin_alpha plugin_beta])
      expect(result.provenances).to eq([builtin, plugin_alpha, plugin_beta])
    end
  end
end
