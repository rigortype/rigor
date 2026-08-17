# frozen_string_literal: true

require "rigor"
require "rigor/analysis/rule_catalog"

# ADR-92 status fidelity for the `effect.*` family, at the identifier level rather than the family
# level `manual_drift_spec.rb` gates.
#
# The failure this exists for is the one ADR-92 was written about: an identifier that is reserved in
# the taxonomy, then implemented, and whose reservation nobody deletes. The family row keeps saying
# "no implemented diagnostic", the family-level gate stays green (the family DOES emit — its sibling
# does), and the document quietly becomes wrong about the very thing it is normative for.
EFFECT_TAXONOMY_DOCS_ROOT = File.expand_path("../../docs", __dir__)

RSpec.describe "the `effect.*` diagnostic taxonomy" do
  let(:policy) do
    File.read(File.join(EFFECT_TAXONOMY_DOCS_ROOT, "type-specification", "diagnostic-policy.md"), encoding: "utf-8")
  end
  let(:effect_labels) do
    File.read(File.join(EFFECT_TAXONOMY_DOCS_ROOT, "type-specification", "effect-labels.md"), encoding: "utf-8")
  end
  let(:implemented) do
    Rigor::Analysis::CheckRules::ALL_RULES.select { |rule| rule.start_with?("effect.") }
  end

  it "implements exactly the ids the taxonomy calls implemented" do
    expect(implemented.sort).to eq(
      ["effect.annotations-unchecked", "effect.envelope-exceeded", "effect.liskov-widened",
       "effect.unknown-label"]
    )
  end

  it "gives every implemented `effect.*` id its own taxonomy row" do
    missing = implemented.reject { |rule| policy.include?("| `#{rule}` |") }

    expect(missing).to be_empty,
                       "Implemented `effect.*` ids with no row in diagnostic-policy.md: #{missing.inspect}"
  end

  # The reservation must expire the moment the id ships, or the normative document says the opposite
  # of what the engine does.
  it "no longer describes an implemented id as reserved" do
    reserved_clause = policy[/identifiers are reserved with no implemented diagnostic:.*?\|/m].to_s
    still_reserved = implemented.select { |rule| reserved_clause.include?("`#{rule}`") }

    expect(still_reserved).to be_empty,
                              "diagnostic-policy.md still reserves ids that now ship: #{still_reserved.inspect}"
  end

  it "carries an implemented marker on effect-labels.md § Unknown labels" do
    section = effect_labels[/^## Unknown labels$.*?(?=^## )/m].to_s

    expect(section).to include("**Implemented as of this writing**")
    expect(section).not_to include("Not implemented as of this writing")
  end

  it "gives every implemented `effect.*` id a rule-catalogue entry" do
    missing = implemented.reject { |rule| Rigor::Analysis::RuleCatalog.resolve(rule).size == 1 }

    expect(missing).to be_empty, "Implemented `effect.*` ids missing from RuleCatalog: #{missing.inspect}"
  end

  it "gives every implemented `effect.*` id a severity in all three profiles" do
    missing = implemented.reject do |rule|
      Rigor::Configuration::SeverityProfile::PROFILES.values.all? { |table| table.key?(rule) }
    end

    expect(missing).to be_empty,
                       "Implemented `effect.*` ids missing from a severity-profile table: #{missing.inspect}"
  end
end
