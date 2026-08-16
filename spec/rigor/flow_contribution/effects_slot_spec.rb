# frozen_string_literal: true

require "rigor"

# ADR-103 WD5 / #383 — the ninth `FlowContribution` slot: an effect-label upper bound attributed at a call
# edge. Adding a slot is an ADR-2 public-API expansion, documented in
# `docs/internal-spec/flow-contribution.md` § Stability.
#
# The slot exists and merges; its PRODUCERS are later slices (#385's config attribution, #387's plugin
# attributions), so nothing in the engine reads it yet.
RSpec.describe "Rigor::FlowContribution effects slot" do
  def labels(*names)
    Rigor::Effects::LabelSet.new(names)
  end

  def bundle(effects, family: :rbs_extended)
    Rigor::FlowContribution.new(
      effects: effects,
      provenance: Rigor::FlowContribution::Provenance.new(
        source_family: family, plugin_id: nil, node: nil, descriptor: nil
      )
    )
  end

  it "is a declared slot" do
    expect(Rigor::FlowContribution::SLOT_NAMES).to include(:effects)
  end

  it "defaults to nil — the contribution asserts nothing about effects" do
    expect(Rigor::FlowContribution.new.effects).to be_nil
  end

  # `nil` and ∅ are different claims: "says nothing" versus "performs none of them", which is what
  # `%a{pure}` asserts. An empty fact Array reads as unset; an empty LabelSet must not.
  it "treats an empty label set as a positive claim rather than an unset slot" do
    expect(bundle(Rigor::Effects::LabelSet::EMPTY).empty?).to be(false)
    expect(Rigor::FlowContribution.new.empty?).to be(true)
  end

  it "flattens into the element list under its own kind" do
    element = bundle(labels("io.db")).to_element_list.first

    expect([element.target, element.edge, element.kind]).to eq(%i[effects normal effects])
  end

  describe "merging" do
    it "unions across contributions, whatever their authority tier" do
      merged = Rigor::FlowContribution::Merger.merge(
        [bundle(labels("io.db")), bundle(labels("nondet.time"), family: "plugin.demo")]
      )

      expect(merged.effects.to_a).to eq(%w[io.db nondet.time])
    end

    it "leaves the slot nil when no contribution speaks" do
      expect(Rigor::FlowContribution::Merger.merge([Rigor::FlowContribution.new]).effects).to be_nil
    end

    # Union is the conservative direction and the only coherent one: a label set is an UPPER BOUND, so
    # two sources that each name part of a footprint together name more of it. There is no reading under
    # which one cancels the other, so there is no conflict to report either.
    it "reports no conflict for disjoint claims" do
      merged = Rigor::FlowContribution::Merger.merge(
        [bundle(Rigor::Effects::LabelSet::EMPTY), bundle(labels("io.db"))]
      )

      expect(merged.conflicts).to be_empty
      expect(merged.effects.to_a).to eq(["io.db"])
    end
  end
end
