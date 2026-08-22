# frozen_string_literal: true

require "rigor/analysis/rule_catalog"

RSpec.describe Rigor::Analysis::RuleCatalog do
  describe "completeness" do
    it "carries a catalogue entry for every rule in CheckRules::ALL_RULES" do
      missing = Rigor::Analysis::CheckRules::ALL_RULES.reject { |r| described_class::ENTRIES.key?(r) }
      expect(missing).to be_empty,
                         "ALL_RULES with no RuleCatalog entry: #{missing.inspect}\n" \
                         "Add an Entry (and its evidence_tier) to lib/rigor/analysis/rule_catalog.rb."
    end

    it "assigns every non-informational entry a known evidence tier" do
      bad = described_class::ENTRIES.values.reject do |entry|
        entry.evidence_tier.nil? || %i[high medium low].include?(entry.evidence_tier)
      end
      expect(bad.map(&:id)).to be_empty
    end
  end

  describe ".evidence_tier" do
    it "returns the per-rule tier for a canonical id" do
      expect(described_class.evidence_tier("call.undefined-method")).to eq(:high)
      expect(described_class.evidence_tier("call.unresolved-toplevel")).to eq(:low)
      expect(described_class.evidence_tier("flow.always-truthy-condition")).to eq(:medium)
    end

    it "resolves a legacy alias to the canonical entry's tier" do
      expect(described_class.evidence_tier("undefined-method")).to eq(:high)
    end

    it "is nil for an informational rule, a family token, and an unknown token" do
      expect(described_class.evidence_tier("dump.type")).to be_nil
      expect(described_class.evidence_tier("call")).to be_nil
      expect(described_class.evidence_tier("plugin.whatever.rule")).to be_nil
    end
  end

  describe ".documentation_url" do
    it "points at the rule's per-rule anchor in the published catalogue" do
      expect(described_class.documentation_url("call.undefined-method"))
        .to eq("https://rigor.typedduck.fail/manual/04-diagnostics/#rule-call-undefined-method")
      expect(described_class.documentation_url("def.return-type-mismatch"))
        .to end_with("#rule-def-return-type-mismatch")
    end

    it "resolves a legacy alias to the canonical anchor" do
      expect(described_class.documentation_url("undefined-method"))
        .to end_with("#rule-call-undefined-method")
    end

    it "is nil for a family token and an unknown / non-built-in token" do
      expect(described_class.documentation_url("call")).to be_nil
      expect(described_class.documentation_url("no.such-rule")).to be_nil
    end
  end

  describe "Entry#to_h" do
    let(:entry) { described_class.resolve("call.undefined-method").first }

    it "serialises the evidence tier as a string and the documentation URL" do
      hash = entry.to_h
      expect(hash["evidence_tier"]).to eq("high")
      expect(hash["documentation_url"]).to end_with("#rule-call-undefined-method")
    end

    it "omits evidence_tier for an informational entry" do
      hash = described_class.resolve("dump.type").first.to_h
      expect(hash).not_to have_key("evidence_tier")
      expect(hash["documentation_url"]).to end_with("#rule-dump-type")
    end
  end
end
