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

  describe "#to_h" do
    it "round-trips through Configuration::Dependencies.from_h" do
      original = described_class.from_h(
        "source_inference" => [
          { "gem" => "rack", "mode" => "full", "roots" => %w[lib bin] },
          { "gem" => "faraday" }
        ]
      )

      reparsed = described_class.from_h(original.to_h)

      expect(reparsed.source_inference.length).to eq(2)
      expect(reparsed.source_inference[0].gem).to eq("rack")
      expect(reparsed.source_inference[0].mode).to eq(:full)
      expect(reparsed.source_inference[0].roots).to eq(%w[lib bin])
      expect(reparsed.source_inference[1].gem).to eq("faraday")
      expect(reparsed.source_inference[1].mode).to eq(:when_missing)
      expect(reparsed.source_inference[1].roots).to eq(%w[lib])
    end

    it "emits the mode as its String spelling so the form survives YAML.dump round-trips" do
      deps = described_class.from_h(
        "source_inference" => [{ "gem" => "rack", "mode" => "when_missing" }]
      )

      expect(deps.to_h.dig("source_inference", 0, "mode")).to eq("when_missing")
    end
  end
end
