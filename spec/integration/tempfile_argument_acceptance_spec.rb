# frozen_string_literal: true

# Issue #3321 — a `Tempfile` passed where `IO` or `File` is declared reported `call.argument-type-mismatch`, because the
# subtype check read the analyzer process's own `Tempfile < Delegator` instead of the RBS `class Tempfile < File`.
require "spec_helper"
# `rigor check` requires `tempfile` itself; load it here so the host hierarchy the bug read is present, whatever order
# the suite runs in.
require "tempfile"

RSpec.describe "a Tempfile argument against an IO or File parameter (#3321)", type: :runner do
  let(:signature) do
    { "report_writer.rbs" => "class ReportWriter\n  def self.write: (IO io) -> void\n  " \
                             "def self.write_file: (File file) -> void\n  def self.count: (Integer n) -> void\nend\n" }
  end

  def mismatches(source)
    analyze(source, sig: signature).diagnostics.map(&:qualified_rule).grep(/argument-type-mismatch/)
  end

  it "accepts a Tempfile for an IO parameter" do
    expect(mismatches("require 'tempfile'\nReportWriter.write(Tempfile.new('report'))\n")).to eq([])
  end

  it "accepts a Tempfile for a File parameter" do
    expect(mismatches("require 'tempfile'\nReportWriter.write_file(Tempfile.new('report'))\n")).to eq([])
  end

  it "still reports an Integer for an IO parameter (the control that the rule is live)" do
    expect(mismatches("ReportWriter.write(1)\n")).to eq(["call.argument-type-mismatch"])
  end

  it "still reports a Tempfile for an Integer parameter (neither hierarchy relates them)" do
    expect(mismatches("require 'tempfile'\nReportWriter.count(Tempfile.new('report'))\n"))
      .to eq(["call.argument-type-mismatch"])
  end
end
