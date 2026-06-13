# frozen_string_literal: true

require "rigor/bleeding_edge"

# ADR-50 § WD2 — the bleeding-edge overlay. The shipped overlay is
# empty (the foundation slice); the non-empty behaviour is exercised by
# stubbing FEATURES so the resolution logic the first real feature will
# rely on is covered now.
RSpec.describe Rigor::BleedingEdge do
  describe "the shipped (empty) overlay" do
    it "carries no features yet" do
      expect(described_class.features).to be_empty
      expect(described_class.feature_ids).to eq([])
    end

    it "resolves every selector to an empty severity map" do
      %w[none all list].each do |mode|
        selector = { "mode" => mode, "ids" => ["x"], "except" => ["x"] }
        expect(described_class.severity_overrides_for(selector)).to eq({})
      end
    end
  end

  context "with a populated overlay (stubbed)" do
    let(:feature_a) do
      described_class::Feature.new(
        id: "feat-a", summary: "promote flow.x", severity_overrides: { "flow.x" => :error }
      )
    end
    let(:feature_b) do
      described_class::Feature.new(
        id: "feat-b", summary: "enable call.y", severity_overrides: { "call.y" => :warning }
      )
    end

    before { stub_const("Rigor::BleedingEdge::FEATURES", [feature_a, feature_b].freeze) }

    it "adopts the whole overlay for mode all" do
      selector = { "mode" => "all" }
      expect(described_class.active_features(selector)).to contain_exactly(feature_a, feature_b)
      expect(described_class.severity_overrides_for(selector)).to eq("flow.x" => :error, "call.y" => :warning)
    end

    it "honours an except list under mode all" do
      selector = { "mode" => "all", "except" => ["feat-a"] }
      expect(described_class.active_features(selector)).to contain_exactly(feature_b)
      expect(described_class.severity_overrides_for(selector)).to eq("call.y" => :warning)
    end

    it "adopts only the named ids under mode list" do
      selector = { "mode" => "list", "ids" => ["feat-a"] }
      expect(described_class.active_features(selector)).to contain_exactly(feature_a)
      expect(described_class.severity_overrides_for(selector)).to eq("flow.x" => :error)
    end

    it "adopts nothing under mode none" do
      expect(described_class.active_features("mode" => "none")).to eq([])
      expect(described_class.severity_overrides_for("mode" => "none")).to eq({})
    end

    it "returns a frozen severity map (Ractor-shareable)" do
      expect(described_class.severity_overrides_for("mode" => "all")).to be_frozen
    end

    it "reports selected ids absent from the overlay" do
      expect(described_class.unknown_selected_ids("mode" => "list", "ids" => %w[feat-a ghost])).to eq(["ghost"])
      expect(described_class.unknown_selected_ids("mode" => "all", "except" => %w[ghost])).to eq(["ghost"])
      expect(described_class.unknown_selected_ids("mode" => "none")).to eq([])
    end

    it "exposes a feature by id" do
      expect(described_class.feature("feat-a")).to eq(feature_a)
      expect(described_class.feature("missing")).to be_nil
    end
  end

  describe "Feature#to_h" do
    it "renders the contract-vocabulary shape with string severities" do
      feature = described_class::Feature.new(
        id: "feat", summary: "s", severity_overrides: { "flow.x" => :error }
      )
      expect(feature.to_h).to eq(
        "id" => "feat", "summary" => "s", "severity_overrides" => { "flow.x" => "error" }
      )
    end
  end
end
