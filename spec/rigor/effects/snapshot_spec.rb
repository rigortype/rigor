# frozen_string_literal: true

require "json"
require "yaml"

require "rigor/configuration"
require "rigor/effects/propagator"
require "rigor/effects/snapshot"

# ADR-103 #381 — the committed effect snapshot as a document: what it records, what it omits, and the
# properties a reviewer and a sibling implementation read it by. The end-to-end behaviour of the verbs
# that write and compare it is `spec/rigor/cli/effects_snapshot_command_spec.rb`.
RSpec.describe Rigor::Effects::Snapshot do
  def summary(*names, exhaustive: true, causes: [], origin: Rigor::Effects::Origin.catalogue("File.read"))
    bundles = names.empty? ? {} : { origin => Rigor::Effects::LabelSet.new(names) }
    Rigor::Effects::Summary.new(bundles: bundles, exhaustive: exhaustive, causes: causes)
  end

  def edge(receiver, selector)
    Rigor::Effects::FileCollection::Edge.new(
      receiver_class: receiver, kind: :instance, selector: selector, self_call: false
    )
  end

  def table(summaries, edges = {})
    Rigor::Effects::Propagator.propagate(
      Rigor::Effects::FileCollection.new(summaries: summaries, edges: edges)
    )
  end

  def configuration(effects = {})
    Rigor::Configuration.new({ "effects" => effects })
  end

  def build(summaries, edges = {}, effects: {}, sources: {}, full: false)
    described_class.build(
      table: table(summaries, edges), configuration: configuration(effects),
      sources: sources, full: full, project_root: "/project"
    )
  end

  describe "the methods table" do
    # DIRECT, never transitive: an entry moves only when its own lines, the catalogue or an attribution
    # moved, which is what keeps a snapshot diff attributable to the pull request that caused it.
    it "records the direct summary and not the transitive one" do
      snapshot = build({ "A#outer" => summary, "A#inner" => summary("io.fs.read") },
                       { "A#outer" => [edge("A", "inner")] })

      expect(snapshot.methods.keys).to eq(["A#inner"])
      expect(snapshot.methods.fetch("A#inner").effects).to eq(["io.fs.read"])
    end

    it "omits an exhaustive method proving nothing beyond mutate.local, and lists it under full" do
      summaries = { "A#pure" => summary, "A#owned" => summary("mutate.local") }

      expect(build(summaries).methods).to be_empty
      expect(build(summaries, full: true).methods.keys).to eq(["A#owned", "A#pure"])
    end

    # A synthesised accessor's summary restates the `attr_accessor` line; a reviewer never acts on it.
    # A hand-written `def name=` keeps its row, because its origins are not the synthesised construct.
    it "omits a synthesised accessor summary but keeps a hand-written writer" do
      synthesised = summary("mutate.self", origin: Rigor::Effects::Origin.construct("attr-writer"))
      handwritten = summary("mutate.self", origin: Rigor::Effects::Origin.construct("ivar-write"))

      snapshot = build({ "A#name=" => synthesised, "A#rename" => handwritten })

      expect(snapshot.methods.keys).to eq(["A#rename"])
    end

    it "records the exhaustiveness bit and the causes behind it, omitting both when exhaustive" do
      snapshot = build(
        { "A#clean" => summary("io"),
          "A#tainted" => summary("io", exhaustive: false, causes: [["unresolved-self-call", "save!"]]) }
      )

      expect(snapshot.methods.fetch("A#clean").to_h).to eq("effects" => ["io"])
      expect(snapshot.methods.fetch("A#tainted").to_h).to eq(
        "effects" => ["io"], "exhaustive" => false, "unresolved" => ["unresolved-self-call(save!)"]
      )
    end
  end

  describe "the reach table" do
    let(:summaries) { { "A#action" => summary, "A#leaf" => summary("io.net.http") } }
    let(:edges) { { "A#action" => [edge("A", "leaf")] } }

    it "is empty by default, because effects.snapshot.reach: is" do
      expect(build(summaries, edges).reach).to be_empty
    end

    # TRANSITIVE at the entry point: the fan-out IS the information (blast radius), which is the one
    # place a leaf change is supposed to be visible from far away.
    it "records the transitive footprint of every unit defined in a matching file" do
      snapshot = build(summaries, edges,
                       effects: { "snapshot" => { "reach" => ["app/**/*.rb"] } },
                       sources: { "A#action" => ["/project/app/controllers/a.rb"] })

      expect(snapshot.reach.keys).to eq(["A#action"])
      expect(snapshot.reach.fetch("A#action").effects).to eq(["io.net.http"])
    end

    it "leaves out a unit whose defining file no glob matches" do
      snapshot = build(summaries, edges,
                       effects: { "snapshot" => { "reach" => ["app/**/*.rb"] } },
                       sources: { "A#leaf" => ["/project/lib/a.rb"] })

      expect(snapshot.reach).to be_empty
    end
  end

  describe "the header" do
    it "carries the schema, the Rigor version and the vocabulary version" do
      header = build({}).header

      expect(header).to include("schema" => described_class::SCHEMA, "rigor" => Rigor::VERSION,
                                "vocabulary" => Rigor::Effects::Registry.default.vocabulary_version)
    end

    # A `tolerated:` edit or a Rigor upgrade is a VISIBLE regeneration event rather than a silent
    # reinterpretation of the record — `db/schema.rb` after a Rails upgrade.
    it "digests the effects: block, so a policy edit changes the header" do
      plain = build({}).header.fetch("config_digest")
      toleranced = build({}, effects: { "tolerated" => ["nondet.time"] }).header.fetch("config_digest")

      expect(plain).to match(/\A[0-9a-f]{64}\z/)
      expect(toleranced).not_to eq(plain)
    end

    it "digests independently of the order the block's keys were written in" do
      one = build({}, effects: { "tolerated" => ["nondet.time"], "views" => false })
      other = build({}, effects: { "views" => false, "tolerated" => ["nondet.time"] })

      expect(one.header).to eq(other.header)
    end
  end

  describe "serialisation" do
    let(:snapshot) do
      build(
        { "A#tainted" => summary("io.fs.read", exhaustive: false, causes: [["dynamic-send", nil]]),
          "Top::Level.singleton" => summary("nondet.time") }
      )
    end

    it "round-trips through parse unchanged" do
      expect(described_class.parse(snapshot.to_yaml)).to eq(snapshot)
    end

    it "is a JSON-compatible YAML subset — no anchors, no tags, string keys" do
      loaded = YAML.safe_load(snapshot.to_yaml)

      expect(JSON.parse(JSON.generate(loaded))).to eq(loaded)
      expect(snapshot.to_yaml).not_to match(/[&*!]/)
    end

    it "sorts keys and labels, and carries no timestamp" do
      text = build({ "B#z" => summary("nondet.time", "io.fs.read"), "A#a" => summary("io") }).to_yaml

      expect(text.index('"A#a"')).to be < text.index('"B#z"')
      expect(text).to include('effects: ["io.fs.read", "nondet.time"]')
      expect(text).not_to match(/\d{4}-\d{2}-\d{2}/)
    end

    it "renders an empty table as an empty mapping rather than dropping the key" do
      expect(build({}).to_yaml).to include("methods: {}\n", "reach: {}\n")
    end

    it "rejects a file that is not a snapshot" do
      expect { described_class.parse("- 1\n") }.to raise_error(described_class::ParseError)
      expect { described_class.parse("methods:\n  \"A#m\": 3\n") }.to raise_error(described_class::ParseError)
    end
  end

  # The record is UNDISCHARGED (invariant 1 of the design note § 4: the catalogue never lies). Policy is
  # applied by `SnapshotDiff` at judgment time, so the file is a pure function of code, catalogue, config
  # and Rigor version.
  it "records the same sets whatever effects.tolerated: says" do
    summaries = { "A#m" => summary("nondet.time") }
    plain = build(summaries)
    toleranced = build(summaries, effects: { "tolerated" => ["nondet.time"] })

    expect(toleranced.methods).to eq(plain.methods)
  end

  describe ".expand_reach" do
    around do |example|
      Rigor::Effects::EntryPoints.reset!
      example.run
      Rigor::Effects::EntryPoints.reset!
    end

    it "passes a glob through and resolves a registered preset to its globs" do
      Rigor::Effects::EntryPoints.register("rails-actions", ["app/controllers/**/*.rb"])

      expect(described_class.expand_reach(["lib/**/*.rb", "rails-actions"]))
        .to eq(["app/controllers/**/*.rb", "lib/**/*.rb"])
    end
  end
end
