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
        "rbs.coverage.environment-build-failed" => :error,
        "rbs.coverage.definition-build-failed" => :error
      )

      adopted = described_class.severity_overrides_for({ "mode" => "all" })
      expect(adopted["rbs.coverage.quarantined-signature"]).to eq(:error)
      expect(adopted["rbs.coverage.environment-build-failed"]).to eq(:error)
      # Issue #696 — the per-class rung of the same ladder: one file, one class, the whole env.
      expect(adopted["rbs.coverage.definition-build-failed"]).to eq(:error)

      # Off by default — an existing green build must not turn red on upgrade.
      expect(described_class.severity_overrides_for({ "mode" => "none" })).to eq({})
    end

    it "carries both kinds today, and has graduated nothing" do
      expect(described_class::FEATURES.map(&:kind).uniq).to contain_exactly(:severity, :behaviour)
      expect(described_class::GRADUATED).to eq([])
    end

    # ADR-103 WD15 — the v0.4.0 default-on preview. Its gate is `Configuration#effects_enabled?` /
    # `Configuration.load`, not an engine call site, so the registry entry carries no severity map either.
    it "ships effects-on-by-default as a behaviour feature with no severity diff" do
      feature = described_class.feature("effects-on-by-default")
      expect(feature.kind).to eq(:behaviour)
      expect(feature).to be_behaviour
      expect(feature.severity_overrides).to be_empty
      expect(described_class.severity_overrides_for({ "mode" => "all" })).not_to have_key("effects-on-by-default")
      expect(described_class.active_ids_for({ "mode" => "none" })).not_to include(feature.id)
      expect(described_class.active_ids_for({ "mode" => "all" })).to include(feature.id)
    end

    # Issue #253 — the first shipped `:behaviour` feature. Its gate is `Configuration#bleeding_edge_active?`
    # at one CLI call site, so the registry entry must carry no severity map at all: a queued change that also
    # moved a rule's severity would be two changes wearing one id.
    it "ships the Tier-2 discovery seed as a behaviour feature with no severity diff" do
      feature = described_class.feature("discovery-seeded-mutation-sites")
      expect(feature.kind).to eq(:behaviour)
      expect(feature).to be_behaviour
      expect(feature.severity_overrides).to be_empty
      expect(described_class.severity_overrides_for({ "mode" => "all" }))
        .not_to have_key("discovery-seeded-mutation-sites")
      expect(described_class.active_ids_for({ "mode" => "none" })).not_to include(feature.id)
    end

    # Issue #254 — the second Tier-2 behaviour feature. It is a separate id on purpose: it changes where a
    # kill may LAND (the dependent closure), not which sites are measured, and the two compose in any
    # combination — so a project adopting one must not be opted into the other.
    it "ships the Tier-2 dependent-closure kill oracle as its own behaviour feature" do
      feature = described_class.feature("dependent-closure-kill-oracle")
      expect(feature.kind).to eq(:behaviour)
      expect(feature.severity_overrides).to be_empty
      expect(described_class.active_ids_for({ "mode" => "none" })).not_to include(feature.id)
      expect(described_class.active_ids_for({ "mode" => "list", "ids" => ["discovery-seeded-mutation-sites"] }))
        .not_to include(feature.id)
      expect(described_class.active_ids_for({ "mode" => "all" })).to include(feature.id)
    end
  end

  context "with a populated overlay (stubbed)" do
    # Both kinds coexist: `feat-a` moves a severity, `feat-b` changes a measurement and moves none.
    let(:feature_a) do
      described_class::Feature.new(
        id: "feat-a", summary: "promote flow.x", kind: :severity, severity_overrides: { "flow.x" => :error }
      )
    end
    let(:feature_b) do
      described_class::Feature.new(id: "feat-b", summary: "count call.y differently", kind: :behaviour)
    end

    before { stub_const("Rigor::BleedingEdge::FEATURES", [feature_a, feature_b].freeze) }

    it "adopts the whole overlay for mode all" do
      selector = { "mode" => "all" }
      expect(described_class.active_features(selector)).to contain_exactly(feature_a, feature_b)
      expect(described_class.severity_overrides_for(selector)).to eq("flow.x" => :error)
      expect(described_class.active_ids_for(selector)).to eq(Set["feat-a", "feat-b"])
    end

    it "honours an except list under mode all" do
      selector = { "mode" => "all", "except" => ["feat-a"] }
      expect(described_class.active_features(selector)).to contain_exactly(feature_b)
      expect(described_class.severity_overrides_for(selector)).to eq({})
      expect(described_class.active_ids_for(selector)).to eq(Set["feat-b"])
    end

    it "adopts only the named ids under mode list" do
      selector = { "mode" => "list", "ids" => ["feat-a"] }
      expect(described_class.active_features(selector)).to contain_exactly(feature_a)
      expect(described_class.severity_overrides_for(selector)).to eq("flow.x" => :error)
      expect(described_class.active_ids_for(selector)).to eq(Set["feat-a"])
    end

    it "selects a behaviour feature by id under mode list" do
      selector = { "mode" => "list", "ids" => ["feat-b"] }
      expect(described_class.active_features(selector)).to contain_exactly(feature_b)
      expect(described_class.active_ids_for(selector)).to eq(Set["feat-b"])
    end

    it "adopts nothing under mode none" do
      expect(described_class.active_features("mode" => "none")).to eq([])
      expect(described_class.severity_overrides_for("mode" => "none")).to eq({})
      expect(described_class.active_ids_for("mode" => "none")).to be_empty
    end

    it "returns a frozen id set (Ractor-shareable)" do
      expect(described_class.active_ids_for("mode" => "all")).to be_frozen
    end

    it "knows every queued id, and nothing else" do
      expect(described_class.known_id?("feat-b")).to be(true)
      expect(described_class.known_id?("ghost")).to be(false)
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

  describe "Feature" do
    it "renders the contract-vocabulary shape with string severities" do
      feature = described_class::Feature.new(
        id: "feat", summary: "s", kind: :severity, severity_overrides: { "flow.x" => :error }
      )
      expect(feature.to_h).to eq(
        "id" => "feat", "summary" => "s", "kind" => "severity", "severity_overrides" => { "flow.x" => "error" }
      )
    end

    it "renders a behaviour feature with an empty severity map" do
      feature = described_class::Feature.new(id: "feat", summary: "s", kind: :behaviour)
      expect(feature.to_h).to eq(
        "id" => "feat", "summary" => "s", "kind" => "behaviour", "severity_overrides" => {}
      )
      expect(feature).to be_behaviour
      expect(feature).not_to be_severity
    end

    # The invariants are what keep a feature id naming exactly one change: a severity feature that promotes
    # nothing is inert, and a behaviour feature that also moves a severity is two changes under one id.
    it "rejects a severity feature that overrides no rule" do
      expect { described_class::Feature.new(id: "feat", summary: "s", kind: :severity) }
        .to raise_error(ArgumentError, /:severity but overrides no rule/)
      expect do
        described_class::Feature.new(id: "feat", summary: "s", kind: :severity, severity_overrides: {})
      end.to raise_error(ArgumentError, /:severity but overrides no rule/)
    end

    it "rejects a behaviour feature that carries severity overrides" do
      expect do
        described_class::Feature.new(
          id: "feat", summary: "s", kind: :behaviour, severity_overrides: { "flow.x" => :error }
        )
      end.to raise_error(ArgumentError, /:behaviour but carries severity_overrides/)
    end

    it "rejects an unknown kind" do
      expect { described_class::Feature.new(id: "feat", summary: "s", kind: :discipline) }
        .to raise_error(ArgumentError, /kind must be one of/)
    end
  end
end
