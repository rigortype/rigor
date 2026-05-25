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
end
