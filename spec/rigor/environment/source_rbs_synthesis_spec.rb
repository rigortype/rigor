# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #1536 — the per-file digest the incremental session compares across an edit (ADR-89 WD1). It must move
# whenever what the loader would read for the file moves, from ANY loaded synthesizer, and must say "unknown"
# rather than guess when it cannot read an output.
RSpec.describe Rigor::Environment::SourceRbsSynthesis do
  let(:none) { described_class::NO_CONTRIBUTION }
  let(:path) { File.join(Dir.mktmpdir("rigor-source-rbs-digest-"), "a.rb") }

  before { File.write(path, "class A\nend\n") }
  after { FileUtils.rm_rf(File.dirname(path)) }

  # The digest reads only a plugin's id (and, with a store, its entry); no plugin needs to be loaded.
  def synthesizer(id, &body)
    plugin = Struct.new(:manifest).new(Struct.new(:id).new(id))
    [plugin, body]
  end

  def digest(*synthesizers)
    described_class.digest(synthesizers, path, nil)
  end

  it "answers the no-contribution sentinel when no synthesizer is loaded or none contributes" do
    expect(digest).to eq(none)
    expect(digest(synthesizer("a") { nil }, synthesizer("b") { "" })).to eq(none)
  end

  it "answers a hex digest that moves with the rendered RBS and with the plugin that rendered it" do
    string = digest(synthesizer("a") { "class A\n  def x: () -> String\nend\n" })
    integer = digest(synthesizer("a") { "class A\n  def x: () -> Integer\nend\n" })
    other_plugin = digest(synthesizer("b") { "class A\n  def x: () -> String\nend\n" })

    expect([string, integer, other_plugin]).to all(match(/\A\h{64}\z/))
    expect([string, integer, other_plugin].uniq.size).to eq(3)
  end

  it "counts a notice-only outcome as a contribution" do
    expect(digest(synthesizer("a") { [:error, "RBS::ParsingError: boom"] })).not_to eq(none)
  end

  it "moves when any one of several synthesizers' output moves" do
    fixed = synthesizer("a") { "class A\nend\n" }

    expect(digest(fixed, synthesizer("b") { "class A\n  def y: () -> void\nend\n" }))
      .not_to eq(digest(fixed, synthesizer("b") { "class A\n  def y: () -> bool\nend\n" }))
  end

  it "answers nil, never a guess, when an output cannot be digested" do
    expect(digest(synthesizer("a") { "class A\nend\n" }, synthesizer("b") { -> {} })).to be_nil
  end

  it "reads a raising synthesizer as no contribution, which is what the loader reads too" do
    expect(digest(synthesizer("a") { raise ArgumentError, "boom" })).to eq(none)
  end
end
