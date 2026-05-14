# frozen_string_literal: true

require "rigor/configuration"

RSpec.describe Rigor::Configuration::Dependencies do
  describe ".from_h" do
    it "returns an empty value when the input is nil" do
      deps = described_class.from_h(nil)

      expect(deps.source_inference).to eq([])
      expect(deps).to be_empty
    end

    it "returns an empty value when the Hash has no source_inference: key" do
      deps = described_class.from_h({})

      expect(deps.source_inference).to eq([])
    end

    it "rejects non-Hash inputs" do
      expect { described_class.from_h([]) }
        .to raise_error(ArgumentError, /must be a Hash/)
    end

    describe "source_inference[] entries" do
      it "parses gem / mode / roots into a frozen Entry" do
        deps = described_class.from_h(
          "source_inference" => [
            { "gem" => "rack", "mode" => "full", "roots" => %w[lib bin] }
          ]
        )

        entry = deps.source_inference.first
        expect(entry.gem).to eq("rack")
        expect(entry.mode).to eq(:full)
        expect(entry.roots).to eq(%w[lib bin])
        expect(entry).to be_frozen
        expect(entry.roots).to be_frozen
      end

      it "defaults mode: to :when_missing when omitted" do
        deps = described_class.from_h(
          "source_inference" => [{ "gem" => "rack" }]
        )

        expect(deps.source_inference.first.mode).to eq(:when_missing)
      end

      it "defaults roots: to ['lib'] when omitted" do
        deps = described_class.from_h(
          "source_inference" => [{ "gem" => "rack" }]
        )

        expect(deps.source_inference.first.roots).to eq(%w[lib])
      end

      it "exposes mode predicates on the Entry" do
        full_entry = described_class.from_h(
          "source_inference" => [{ "gem" => "rack", "mode" => "full" }]
        ).source_inference.first
        when_missing_entry = described_class.from_h(
          "source_inference" => [{ "gem" => "rack", "mode" => "when_missing" }]
        ).source_inference.first
        disabled_entry = described_class.from_h(
          "source_inference" => [{ "gem" => "rack", "mode" => "disabled" }]
        ).source_inference.first

        expect(full_entry).to be_full
        expect(when_missing_entry).to be_when_missing
        expect(disabled_entry).to be_disabled
      end

      it "rejects entries that are not a Hash" do
        expect { described_class.from_h("source_inference" => ["rack"]) }
          .to raise_error(ArgumentError, /must be a Hash/)
      end

      it "rejects entries missing the gem: key" do
        expect { described_class.from_h("source_inference" => [{ "mode" => "full" }]) }
          .to raise_error(ArgumentError, /gem must be a non-empty String/)
      end

      it "rejects entries with an empty gem: name" do
        expect { described_class.from_h("source_inference" => [{ "gem" => "" }]) }
          .to raise_error(ArgumentError, /gem must be a non-empty String/)
      end

      it "rejects entries with an unknown mode:" do
        expect do
          described_class.from_h(
            "source_inference" => [{ "gem" => "rack", "mode" => "always" }]
          )
        end.to raise_error(ArgumentError, /mode must be one of/)
      end

      it "rejects entries with an explicitly empty roots: array (omit the key instead)" do
        expect do
          described_class.from_h(
            "source_inference" => [{ "gem" => "rack", "roots" => [] }]
          )
        end.to raise_error(ArgumentError, /roots must not be empty/)
      end
    end
  end

  describe "#budget_per_gem (slice 4)" do
    it "defaults to DEFAULT_BUDGET_PER_GEM (5000) when the key is omitted" do
      deps = described_class.from_h({})

      expect(deps.budget_per_gem).to eq(described_class::DEFAULT_BUDGET_PER_GEM)
      expect(deps.budget_per_gem).to eq(5000)
    end

    it "accepts an Integer within the 0.25× – 4× range" do
      deps = described_class.from_h("budget_per_gem" => 7500)

      expect(deps.budget_per_gem).to eq(7500)
    end

    it "accepts the minimum bound (1250)" do
      deps = described_class.from_h("budget_per_gem" => 1250)

      expect(deps.budget_per_gem).to eq(described_class::MIN_BUDGET_PER_GEM)
    end

    it "accepts the maximum bound (20000)" do
      deps = described_class.from_h("budget_per_gem" => 20_000)

      expect(deps.budget_per_gem).to eq(described_class::MAX_BUDGET_PER_GEM)
    end

    it "rejects non-Integer values" do
      expect { described_class.from_h("budget_per_gem" => "5000") }
        .to raise_error(ArgumentError, /must be an Integer/)
    end

    it "rejects values below the minimum" do
      expect { described_class.from_h("budget_per_gem" => 100) }
        .to raise_error(ArgumentError, /must be in the range/)
    end

    it "rejects values above the maximum" do
      expect { described_class.from_h("budget_per_gem" => 100_000) }
        .to raise_error(ArgumentError, /must be in the range/)
    end
  end

  describe "#to_h" do
    it "round-trips through Configuration::Dependencies.from_h" do
      original = described_class.from_h(
        "source_inference" => [
          { "gem" => "rack", "mode" => "full", "roots" => %w[lib bin] },
          { "gem" => "faraday" }
        ],
        "budget_per_gem" => 8000
      )

      reparsed = described_class.from_h(original.to_h)

      expect(reparsed.source_inference.length).to eq(2)
      expect(reparsed.source_inference[0].gem).to eq("rack")
      expect(reparsed.source_inference[0].mode).to eq(:full)
      expect(reparsed.source_inference[0].roots).to eq(%w[lib bin])
      expect(reparsed.source_inference[1].gem).to eq("faraday")
      expect(reparsed.source_inference[1].mode).to eq(:when_missing)
      expect(reparsed.source_inference[1].roots).to eq(%w[lib])
      expect(reparsed.budget_per_gem).to eq(8000)
    end

    it "emits the mode as its String spelling so the form survives YAML.dump round-trips" do
      deps = described_class.from_h(
        "source_inference" => [{ "gem" => "rack", "mode" => "when_missing" }]
      )

      expect(deps.to_h.dig("source_inference", 0, "mode")).to eq("when_missing")
    end

    it "carries budget_per_gem in the round-tripped Hash" do
      deps = described_class.from_h({})

      expect(deps.to_h["budget_per_gem"]).to eq(described_class::DEFAULT_BUDGET_PER_GEM)
    end
  end

  describe "#budget_overrun_strategy (ADR-10 5b)" do
    it "defaults to :walker_cap" do
      deps = described_class.from_h({})

      expect(deps.budget_overrun_strategy).to eq(:walker_cap)
    end

    it "accepts :dependency_silence" do
      deps = described_class.from_h("budget_overrun_strategy" => "dependency_silence")

      expect(deps.budget_overrun_strategy).to eq(:dependency_silence)
    end

    it "rejects unknown strategy values" do
      expect { described_class.from_h("budget_overrun_strategy" => "tighten_or_explode") }
        .to raise_error(ArgumentError, /budget_overrun_strategy/)
    end
  end

  describe "config-conflict deduplication (ADR-10 5d)" do
    it "collapses idempotent duplicate entries with no warning" do
      deps = described_class.from_h(
        "source_inference" => [
          { "gem" => "rack", "mode" => "when_missing", "roots" => %w[lib] },
          { "gem" => "rack", "mode" => "when_missing", "roots" => %w[lib] }
        ]
      )

      expect(deps.source_inference.length).to eq(1)
      expect(deps.warnings).to be_empty
    end

    it "warns on a mode conflict with later entry winning" do
      deps = described_class.from_h(
        "source_inference" => [
          { "gem" => "rack", "mode" => "when_missing" },
          { "gem" => "rack", "mode" => "full" }
        ]
      )

      expect(deps.source_inference.length).to eq(1)
      expect(deps.source_inference.first.mode).to eq(:full)
      expect(deps.warnings.first).to include("rack")
      expect(deps.warnings.first).to include(":full")
      expect(deps.warnings.first).to include(":when_missing")
    end

    it "unions roots silently across entries with the same mode" do
      deps = described_class.from_h(
        "source_inference" => [
          { "gem" => "rack", "mode" => "when_missing", "roots" => %w[lib] },
          { "gem" => "rack", "mode" => "when_missing", "roots" => %w[lib app] }
        ]
      )

      expect(deps.source_inference.length).to eq(1)
      expect(deps.source_inference.first.roots).to contain_exactly("lib", "app")
      expect(deps.warnings).to be_empty
    end
  end
end
