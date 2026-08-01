# frozen_string_literal: true

require "spec_helper"
require "rigor/cli/mutation_protection_report"
require "rigor/protection/mutation_scanner"

# ADR-63 Tier 2 — aggregation of per-file effectiveness results into a project report: the kill ratio, per-file rows,
# and a ranked "missed breakage" list.
RSpec.describe Rigor::CLI::MutationProtectionReport do
  def file_result(path, killed:, survived:, sites: [], harness_errors: 0)
    Rigor::Protection::MutationScanner::FileResult.new(
      path: path, killed: killed, survived: survived, sites: sites, harness_errors: harness_errors
    )
  end

  def site(line, method, receiver: "String", operator: "undefined_method")
    Rigor::Protection::MutationScanner::SurvivingSite.new(
      line: line, receiver: receiver, method_name: method, operator: operator
    )
  end

  it "aggregates kills and survivors into an effectiveness ratio" do
    acc = Rigor::CLI::MutationProtectionAccumulator.new
    acc.absorb(file_result("a.rb", killed: 3, survived: 1))
    acc.absorb(file_result("b.rb", killed: 6, survived: 0))

    report = acc.to_report
    expect(report.total_killed).to eq(9)
    expect(report.total_survived).to eq(1)
    expect(report.ratio).to be_within(0.0001).of(0.9)
  end

  it "ranks missed breakages by frequency and caps examples at three" do
    acc = Rigor::CLI::MutationProtectionAccumulator.new
    acc.absorb(file_result("a.rb", killed: 0, survived: 4, sites: [
                             site(1, "join"), site(2, "join"), site(3, "join"), site(4, "save")
                           ]))

    report = acc.to_report
    top = report.missed.first
    expect(top.method_name).to eq("join")
    expect(top.count).to eq(3)
    expect(top.examples.size).to eq(3)
  end

  it "exposes the structured fields under to_h (ADR-61 — no message parsing)" do
    acc = Rigor::CLI::MutationProtectionAccumulator.new
    acc.absorb(file_result("a.rb", killed: 1, survived: 1, sites: [site(2, "join")]))

    hash = acc.to_report.to_h
    expect(hash["mode"]).to eq("mutation")
    expect(hash["killed"]).to eq(1)
    expect(hash["survived"]).to eq(1)
    expect(hash["effectiveness_ratio"]).to eq(0.5)
    expect(hash["add_a_type_here"].first).to include("method" => "join", "count" => 1)
  end

  it "is vacuously fully effective with no files" do
    report = Rigor::CLI::MutationProtectionAccumulator.new.to_report
    expect(report.ratio).to eq(1.0)
  end

  it "records a parse error as a path plus the error count" do
    acc = Rigor::CLI::MutationProtectionAccumulator.new
    acc.record_parse_error("broken.rb", %w[err-a err-b])

    expect(acc.to_report.parse_errors).to eq([{ "path" => "broken.rb", "errors" => 2 }])
  end

  # #264 — a rescued harness failure is distinguishable from a parse-invalid mutant: it has its own bucket,
  # summed at the report level, and stays OUT of `total_killed + total_survived` / `ratio` exactly as before.
  it "sums harness_errors across files without moving the effectiveness ratio (#264)" do
    acc = Rigor::CLI::MutationProtectionAccumulator.new
    acc.absorb(file_result("a.rb", killed: 3, survived: 1, harness_errors: 2))
    acc.absorb(file_result("b.rb", killed: 6, survived: 0, harness_errors: 1))

    report = acc.to_report
    expect(report.total_harness_errors).to eq(3)
    expect(report.total_killed).to eq(9)
    expect(report.total_survived).to eq(1)
    expect(report.ratio).to be_within(0.0001).of(0.9) # unchanged from the harness_errors-free case above
  end

  it "exposes harness_errors unconditionally under to_h, even when it is zero (#264)" do
    acc = Rigor::CLI::MutationProtectionAccumulator.new
    acc.absorb(file_result("a.rb", killed: 1, survived: 1))

    hash = acc.to_report.to_h
    expect(hash).to have_key("harness_errors")
    expect(hash["harness_errors"]).to eq(0)
    expect(hash["files"].first).to include("harness_errors" => 0)
  end

  # OFF-path (no rescued failures): the report for a clean fixture is byte-identical to the pre-#264 shape
  # except for the two new always-present `harness_errors` fields.
  it "keeps the clean-fixture to_h identical to the pre-#264 shape plus the new harness_errors fields" do
    acc = Rigor::CLI::MutationProtectionAccumulator.new
    acc.absorb(file_result("a.rb", killed: 1, survived: 1, sites: [site(2, "join")]))

    hash = acc.to_report.to_h

    expect(hash).to eq(
      {
        "mode" => "mutation",
        "killed" => 1,
        "survived" => 1,
        "effectiveness_ratio" => 0.5,
        "harness_errors" => 0,
        "files" => [{ "path" => "a.rb", "killed" => 1, "survived" => 1, "ratio" => 0.5, "harness_errors" => 0 }],
        "add_a_type_here" => [{ "method" => "join", "count" => 1, "examples" => ["a.rb:2"] }],
        "parse_errors" => []
      }
    )
  end
end
