# frozen_string_literal: true

require "rigor/bleeding_edge"

# ADR-50 § WD2 — the bleeding-edge overlay. The shipped overlay carries the queued next-major disciplines; the general
# resolution logic is exercised against a stubbed FEATURES so it stays covered independently of what ships.
RSpec.describe Rigor::BleedingEdge do
  describe "the shipped overlay" do
    it "queues `reject-unparseable-signatures`" do
      expect(described_class.feature_ids).to include("reject-unparseable-signatures")
    end

    it "promotes the broken-signature rules to :error only for a selector that adopts it" do
      feature = described_class.feature("reject-unparseable-signatures")
      expect(feature.severity_overrides).to eq(
        "rbs.coverage.quarantined-signature" => :error,
        "rbs.coverage.environment-build-failed" => :error
      )

      adopted = described_class.severity_overrides_for({ "mode" => "all" })
      expect(adopted["rbs.coverage.quarantined-signature"]).to eq(:error)
      expect(adopted["rbs.coverage.environment-build-failed"]).to eq(:error)

      # Off by default — an existing green build must not turn red on upgrade.
      expect(described_class.severity_overrides_for({ "mode" => "none" })).to eq({})
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
