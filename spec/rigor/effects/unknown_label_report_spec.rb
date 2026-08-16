# frozen_string_literal: true

require "rigor/effects/registry"
require "rigor/effects/unknown_label_check"

# ADR-103 WD1 — the sentence `effect.unknown-label` prints, and the precedence inside it.
RSpec.describe Rigor::Effects::UnknownLabelReport do
  let(:registry) do
    Rigor::Effects::Registry.new(
      vocabulary_version: 1, labels: ["io.db", "io.net"],
      retired: { "io.stdout" => %w[io.output.stdout io.output.stderr] }
    )
  end

  it "answers nil where intent is not evident" do
    expect(described_class.for(token: "database", registry: registry)).to be_nil
  end

  it "quotes the nearest recognised spelling" do
    report = described_class.for(token: "io.bd", registry: registry)

    expect(report.message(subject: "Effect envelope on Foo#bar", consequence: "the annotation now bounds nothing"))
      .to eq(
        "Effect envelope on Foo#bar names io.bd, which is not a known effect label (did you mean " \
        "io.db?); the annotation now bounds nothing."
      )
  end

  # A retirement outranks a guess: the registry KNOWS where the label went, so proposing a
  # nearest-neighbour instead would be strictly worse information.
  it "names every replacement for a retired spelling instead of guessing" do
    report = described_class.for(token: "io.stdout", registry: registry)

    expect(report.message(subject: "Effect envelope on Foo#bar", consequence: "it bounds nothing"))
      .to eq(
        "Effect envelope on Foo#bar names io.stdout, which is not a known effect label (io.stdout " \
        "is retired; write io.output.stdout or io.output.stderr instead); it bounds nothing."
      )
  end

  it "says only that the label is unknown when nothing is close enough to propose" do
    report = described_class.for(token: "widget.render", registry: registry)

    expect(report.message(subject: "Effect envelope on Foo#bar", consequence: "it bounds nothing"))
      .to eq("Effect envelope on Foo#bar names widget.render, which is not a known effect label; it bounds nothing.")
  end
end
