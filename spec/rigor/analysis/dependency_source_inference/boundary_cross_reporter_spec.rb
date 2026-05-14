# frozen_string_literal: true

require "rigor/analysis/dependency_source_inference"

RSpec.describe Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter do
  let(:reporter) { described_class.new }

  it "starts empty" do
    expect(reporter).to be_empty
    expect(reporter.entries).to eq([])
  end

  it "records a boundary-cross event and lifts the fields into an Entry" do
    reporter.record(
      class_name: "Faraday::Connection", method_name: :get,
      gem_name: "faraday", rbs_display: "::Faraday::Response"
    )

    entries = reporter.entries
    expect(entries.size).to eq(1)
    expect(entries.first).to have_attributes(
      class_name: "Faraday::Connection", method_name: :get,
      gem_name: "faraday", rbs_display: "::Faraday::Response"
    )
  end

  it "deduplicates on (class_name, method_name, gem_name) — display variation does not split" do
    reporter.record(class_name: "X", method_name: :f, gem_name: "g", rbs_display: "Integer")
    reporter.record(class_name: "X", method_name: :f, gem_name: "g", rbs_display: "Numeric")

    expect(reporter.entries.size).to eq(1)
  end

  it "records distinct entries for different methods on the same class / gem" do
    reporter.record(class_name: "X", method_name: :f, gem_name: "g", rbs_display: "A")
    reporter.record(class_name: "X", method_name: :h, gem_name: "g", rbs_display: "B")

    expect(reporter.entries.size).to eq(2)
  end

  it "returns a frozen snapshot — subsequent records do not mutate prior snapshots" do
    reporter.record(class_name: "X", method_name: :f, gem_name: "g", rbs_display: "A")
    snapshot = reporter.entries
    reporter.record(class_name: "Y", method_name: :h, gem_name: "g", rbs_display: "B")

    expect(snapshot).to be_frozen
    expect(snapshot.size).to eq(1)
    expect(reporter.entries.size).to eq(2)
  end
end
