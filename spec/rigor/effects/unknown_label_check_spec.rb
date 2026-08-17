# frozen_string_literal: true

require "rigor/effects/registry"
require "rigor/effects/unknown_label_check"

# ADR-103 WD1 — the walk from declarations and config values to findings.
RSpec.describe Rigor::Effects::UnknownLabelCheck do
  let(:registry) do
    Rigor::Effects::Registry.new(vocabulary_version: 1, labels: ["io.db", "io.net"], retired: {})
  end

  describe ".for_config" do
    it "judges each member against the list it was written in" do
      findings = described_class.for_config(
        labels: %w[io.db frobnicate], key_path: "effects.tolerated",
        consequence: "the entry discharges nothing", registry: registry
      )

      expect(findings.map(&:message)).to eq(
        [
          "`effects.tolerated:` in .rigor.yml names frobnicate, which is not a known effect label; " \
          "the entry discharges nothing."
        ]
      )
    end

    it "leaves a list whose members are all recognised alone" do
      findings = described_class.for_config(
        labels: %w[io.db io.net], key_path: "effects.tolerated",
        consequence: "the entry discharges nothing", registry: registry
      )

      expect(findings).to be_empty
    end
  end

  describe ".for_envelopes" do
    # `def self?.x` declares two method keys off ONE annotation. The finding is about the
    # declaration, so it is deduplicated by where it was written, not by which key it bound.
    it "reports one finding per declaration, not per bound method key" do
      envelope = Rigor::Effects::Envelope.build(
        owner_key: "Foo#bar", bound: Rigor::Effects::LabelSet::TOP, source: :effect_annotation,
        location: "sig/foo.rbs:3", spelling: "%a{rigor:v1:effect io.bd}",
        unknown_labels: ["io.bd"], declared_labels: ["io.bd"]
      )
      findings = described_class.for_envelopes(
        method_envelopes: { "Foo#bar" => envelope, "Foo.bar" => envelope.with(owner_key: "Foo.bar") },
        class_envelopes: {}, registry: registry
      )

      expect(findings.size).to eq(1)
    end
  end
end
