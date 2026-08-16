# frozen_string_literal: true

require "spec_helper"

# Pins the shipped vocabulary in `data/effects/registry.yml`. The file is hand-written, not
# generated, and every row is a vocabulary decision recorded in ADR-103 WD2 / WD14 and normative in
# `docs/type-specification/effect-labels.md` — so a change to it must be a deliberate edit here too.
RSpec.describe "the shipped effect-label registry" do
  subject(:registry) { Rigor::Effects::Registry.default }

  # Steins' v1 set, verbatim. Shared vocabulary: a policy naming these must read the same against a
  # PHP service and a Rails app.
  let(:steins_v1) do
    %w[
      exit ffi global.read global.write io io.db io.fs io.fs.read io.fs.write io.input io.ipc
      io.net io.net.http io.output io.output.buffer io.output.header io.output.stdout
      io.output.stderr io.process io.signal mutate mutate.local nondet nondet.random nondet.time
    ]
  end

  # Ruby's `mutate` leaves (Steins ADR-0055's names, ADR-103 WD14): no `mutate.arg`.
  let(:ruby_leaves) { %w[mutate.self mutate.instance mutate.static] }

  # Proposed shared core leaves, to raise with Steins.
  let(:proposed_shared) { %w[io.db.read io.db.write io.db.transaction] }

  # The small shared set of application-meaning roots a policy actually names.
  let(:application_meaning) { %w[telemetry email.send job.enqueue cache.read cache.write] }

  it "carries vocabulary version 1" do
    expect(registry.vocabulary_version).to eq(1)
  end

  it "declares exactly the four groups and nothing else" do
    expected = (steins_v1 + ruby_leaves + proposed_shared + application_meaning).sort

    expect(registry.labels).to eq(expected)
  end

  it "carries Steins' v1 set verbatim" do
    expect(registry.labels).to include(*steins_v1)
  end

  it "spells the `mutate` leaves as WD14 fixed them" do
    expect(registry.labels).to include(*ruby_leaves)
    expect(registry.labels).not_to include("mutate.arg")
  end

  it "declares every label in the grammar" do
    registry.labels.each do |label|
      expect(Rigor::Effects::Label.valid?(label)).to be(true), "#{label.inspect} is not a well-formed label"
    end
  end

  it "ships an empty retired table at vocabulary 1" do
    # Nothing has been renamed or removed yet; an entry here without a version bump would be a
    # vocabulary-evolution violation.
    registry.labels.each { |label| expect(registry.retired(label)).to be_nil }
    expect(registry.retired("io.sql")).to be_nil
  end

  it "opens only the roots the three layers name" do
    expect(registry.roots).to eq(%w[cache email exit ffi global io job mutate nondet telemetry])
  end

  it "recognises the interior nodes a bound may name" do
    %w[io io.db io.fs io.net io.output mutate nondet email job cache].each do |label|
      expect(registry.known?(label)).to be(true), "expected #{label.inspect} to be a recognised bound"
    end
  end

  it "does not recognise a plausible label nobody registered" do
    expect(registry.known?("io.smtp")).to be(false)
    expect(registry.known?("rails.activejob.enqueue")).to be(false)
  end

  it "suggests a registered spelling for a near miss" do
    expect(registry.suggest("nondet.tim")).to eq("nondet.time")
    expect(registry.suggest("io.fs.writ")).to eq("io.fs.write")
  end

  it "is packaged with the gem" do
    # `Registry.default` degrades to an empty vocabulary when the data file is missing, so an
    # omission from the gemspec's file list would be silent at runtime.
    root = File.expand_path("../../..", __dir__)
    spec = Gem::Specification.load(File.join(root, "rigortype.gemspec"))

    expect(spec.files).to include("data/effects/registry.yml")
  end
end
