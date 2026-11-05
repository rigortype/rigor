# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# ADR-129 stage 3 — the CI step's judge of the type_of shadow's reports: it passes only a report that checked at least
# one would-be hit and found no mismatch, so a missing or empty report cannot pass as clean.
RSpec.describe "tool/type_of_shadow_report.rb" do
  let(:script) { File.expand_path("../../tool/type_of_shadow_report.rb", __dir__) }

  def judge(*lines, write: true)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "report.jsonl")
      File.write(path, lines.map { |line| "#{JSON.generate(line)}\n" }.join) if write
      output, status = Open3.capture2e({ "GITHUB_STEP_SUMMARY" => nil }, RbConfig.ruby, script, path, stdin_data: "")
      [status.success?, output]
    end
  end

  def line(counts) = { pid: 1, counts: counts, stale: {}, samples: [] }

  it "passes a report that checked would-be hits and found no mismatch" do
    expect(judge(line(rule: { checked: 3 }), line(main: { checked: 2 })))
      .to match([true, /OK: 5 would-be hits checked/])
  end

  it "fails a mismatch, a missing or empty report, and a run that checked nothing" do
    expect(judge(line(rule: { checked: 3, mismatch: 1 }))).to match([false, /1 mismatch/])
    expect(judge(write: false)).to match([false, /no report written/])
    expect(judge).to match([false, /empty report/])
    expect(judge(line({}))).to match([false, /no would-be hit was checked/])
  end
end
