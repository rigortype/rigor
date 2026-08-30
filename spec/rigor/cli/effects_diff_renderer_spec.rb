# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli/effects_diff_renderer"

# #435 — the position a drift row carries, and the two things it is not allowed to cost: a parse on a
# report with no rows, and a parse of anything but the rows' own files. The vocabulary of the events
# themselves is `spec/rigor/effects/snapshot_diff_spec.rb`; this file is about what the reader sees.
RSpec.describe Rigor::CLI::EffectsDiffRenderer do
  # A verifying double, so "forces nothing" is asserted as zero questions asked rather than as the
  # absence of an observable side effect — and so a renamed resolver fails here rather than passing.
  def counting_lines(answers = {})
    instance_double(Rigor::Effects::DefinitionLines).tap do |lines|
      allow(lines).to receive(:for) { |key:, path:| answers[[key, path]] }
    end
  end

  def header_row(**overrides)
    { "schema" => 2, "rigor" => Rigor::VERSION, "vocabulary" => 1, "config_digest" => "abc" }.merge(overrides)
  end

  def entry(key, effects: [])
    Rigor::Effects::Snapshot::Entry.new(key: key, effects: effects, declared: [], exhaustive: true,
                                        unresolved: [])
  end

  def snapshot(methods)
    Rigor::Effects::Snapshot.new(header: header_row, methods: methods, reach: {})
  end

  def diff_of(before, after)
    Rigor::Effects::SnapshotDiff.compare(recorded: snapshot(before), current: snapshot(after))
  end

  def render(diff, sources:, lines:, format: "text")
    out = StringIO.new
    described_class.new(out: out, path: ".rigor-effects.yml", sources: sources, lines: lines)
                   .render(diff, format: format)
    out.string
  end

  let(:added) do
    diff_of({ "A#m" => entry("A#m") }, { "A#m" => entry("A#m", effects: ["io.fs.read"]) })
  end

  it "prints the def's line beside the file" do
    lines = counting_lines({ ["A#m", "/p/a.rb"] => 12 })

    expect(render(added, sources: { "A#m" => ["/p/a.rb"] }, lines: lines))
      .to include("  A#m  + io.fs.read  (/p/a.rb:12)\n")
  end

  # The whole point of resolving lazily: the common CI case is a report with nothing in it, and it must
  # not pay for a position no row will print (ADR-104's warm path, the #479 shape one layer up).
  it "asks for no position at all when the report is fresh" do
    fresh = diff_of({ "A#m" => entry("A#m") }, { "A#m" => entry("A#m") })
    lines = counting_lines

    expect(render(fresh, sources: { "A#m" => ["/p/a.rb"] }, lines: lines))
      .to eq("No effect drift against .rigor-effects.yml.\n")
    expect(lines).not_to have_received(:for)
  end

  it "asks only about the files the printed rows name" do
    lines = counting_lines
    render(added, sources: { "A#m" => ["/p/a.rb"], "B#other" => ["/p/b.rb"] }, lines: lines)

    expect(lines).to have_received(:for).with(key: "A#m", path: "/p/a.rb").once
    expect(lines).to have_received(:for).once
  end

  it "keeps the file alone when the file spells the key with no def" do
    lines = counting_lines

    expect(render(added, sources: { "A#m" => ["/p/a.rb"] }, lines: lines))
      .to include("  A#m  + io.fs.read  (/p/a.rb)\n")
  end

  # A reopening spans files, and each of them gets its own line — the row names them all rather than
  # picking one, which is the behaviour the file-only suffix already had.
  it "positions every file a reopened unit is defined in" do
    lines = counting_lines({ ["A#m", "/p/a.rb"] => 12, ["A#m", "/p/more.rb"] => 3 })

    expect(render(added, sources: { "A#m" => ["/p/a.rb", "/p/more.rb"] }, lines: lines))
      .to include("  A#m  + io.fs.read  (/p/a.rb:12, /p/more.rb:3)\n")
  end

  # The one row that cannot carry a position, and the reason it cannot: `sources` is the CURRENT run's,
  # and a method the run no longer sees was not defined by it. It renders as it always did.
  it "leaves a removed symbol unannotated" do
    removed = diff_of({ "A#gone" => entry("A#gone", effects: ["io.fs.read"]) }, {})
    lines = counting_lines

    expect(render(removed, sources: {}, lines: lines)).to include("methods:\n  A#gone  -symbol [io.fs.read]\n")
    expect(lines).not_to have_received(:for)
  end

  describe "json" do
    it "carries the same position the text form prints" do
      lines = counting_lines({ ["A#m", "/p/a.rb"] => 12 })
      payload = JSON.parse(render(added, sources: { "A#m" => ["/p/a.rb"] }, lines: lines, format: "json"))

      expect(payload.fetch("events").first.fetch("sources")).to eq([{ "path" => "/p/a.rb", "line" => 12 }])
    end

    it "omits the line it does not have, and the key when there is no source at all" do
      lines = counting_lines
      payload = JSON.parse(render(added, sources: { "A#m" => ["/p/a.rb"] }, lines: lines, format: "json"))
      removed = diff_of({ "A#gone" => entry("A#gone", effects: ["io.fs.read"]) }, {})
      unsourced = JSON.parse(render(removed, sources: {}, lines: lines, format: "json"))

      expect(payload.fetch("events").first.fetch("sources")).to eq([{ "path" => "/p/a.rb" }])
      expect(unsourced.fetch("events").first).not_to have_key("sources")
    end
  end
end
