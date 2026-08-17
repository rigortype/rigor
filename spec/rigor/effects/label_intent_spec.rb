# frozen_string_literal: true

require "rigor/effects/label_intent"
require "rigor/effects/registry"
require "rigor/effects/unknown_label_check"

# ADR-103 WD1 — the intent gate on its own. `effect.unknown-label` exists to make a silent
# degradation visible; this decides where saying so is help and where it is noise.
RSpec.describe Rigor::Effects::LabelIntent do
  let(:registry) do
    Rigor::Effects::Registry.new(
      vocabulary_version: 1, labels: ["io.db", "io.net", "exit", "telemetry"],
      retired: { "io.stdout" => ["io.output.stdout"] }
    )
  end

  describe ".evident?" do
    it "reads a near miss (signal 1)" do
      expect(described_class.evident?("exi", registry)).to be(true)
    end

    it "reads a recognised sibling in the same list (signal 2)" do
      expect(described_class.evident?("frobnicate", registry, siblings: %w[io.db frobnicate])).to be(true)
    end

    it "reads a dotted path as label-shaped whatever it says (signal 3)" do
      expect(described_class.evident?("widget.render", registry)).to be(true)
    end

    it "reads a retired spelling (signal 4)" do
      expect(described_class.evident?("io.stdout", registry)).to be(true)
    end

    it "declines a lone far-off word — an open vocabulary makes it as likely deliberate as wrong" do
      expect(described_class.evident?("database", registry)).to be(false)
    end

    it "declines a recognised label, exactly or as an implied ancestor" do
      expect([described_class.evident?("io.db", registry), described_class.evident?("io", registry)])
        .to eq([false, false])
    end

    it "declines a token outside the label grammar — malformed is a different condition" do
      expect(described_class.evident?("io/db", registry)).to be(false)
    end

    it "declines every token when there is no vocabulary to judge against" do
      expect(described_class.evident?("widget.render", nil)).to be(false)
    end

    it "does not count the token itself as its own recognised sibling" do
      expect(described_class.evident?("database", registry, siblings: %w[database])).to be(false)
    end
  end
end
