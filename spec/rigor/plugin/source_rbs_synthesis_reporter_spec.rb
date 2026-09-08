# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::SourceRbsSynthesisReporter do
  let(:reporter) { described_class.new }

  it "is empty on construction" do
    expect(reporter).to be_empty
    expect(reporter.entries).to eq([])
  end

  it "records (plugin_id, path, message) entries (ADR-32 WD6)" do
    reporter.record(plugin_id: "rbs-inline", path: "/tmp/demo.rb", message: "ParseError: unexpected token")
    reporter.record(plugin_id: "rbs-inline", path: "/tmp/other.rb", message: "ParseError: bad annotation")

    expect(reporter).not_to be_empty
    expect(reporter.entries.size).to eq(2)
    expect(reporter.entries.first.plugin_id).to eq("rbs-inline")
    expect(reporter.entries.first.path).to eq("/tmp/demo.rb")
    expect(reporter.entries.first.message).to eq("ParseError: unexpected token")
  end

  it "freezes each entry's string fields" do
    reporter.record(plugin_id: "rbs-inline", path: "/tmp/demo.rb", message: "boom")
    entry = reporter.entries.first
    expect(entry.plugin_id).to be_frozen
    expect(entry.path).to be_frozen
    expect(entry.message).to be_frozen
  end

  it "returns a frozen snapshot from #entries" do
    reporter.record(plugin_id: "rbs-inline", path: "/tmp/demo.rb", message: "boom")
    expect(reporter.entries).to be_frozen
  end

  # Issue #824 — a worker pool re-runs the whole env build in EVERY worker over the same project file list
  # and drains each worker's stream into this one reporter, so an identical entry arrives once per worker.
  # Each entry becomes one `:info` row, and N copies of one row say nothing the first does not.
  it "collapses an identical entry so a pooled run reports what a sequential one does" do
    3.times { reporter.record(plugin_id: "rbs-inline", path: "/tmp/demo.rb", message: "boom") }
    expect(reporter.entries.size).to eq(1)
  end

  it "keeps entries that differ in any field, kind included" do
    reporter.record(plugin_id: "rbs-inline", path: "/tmp/demo.rb", message: "boom")
    reporter.record(plugin_id: "rbs-inline", path: "/tmp/demo.rb", message: "boom", kind: :not_honoured)
    reporter.record(plugin_id: "rbs-inline", path: "/tmp/other.rb", message: "boom")
    reporter.record(plugin_id: "other", path: "/tmp/demo.rb", message: "boom")
    expect(reporter.entries.size).to eq(4)
  end
end
