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

  def judge(*reports, summary: nil, args: [])
    Dir.mktmpdir do |dir|
      paths = reports.each_with_index.map do |report, index|
        File.join(dir, "report-#{index}.jsonl").tap do |path|
          if report
            File.write(path, report.map do |line|
              line.is_a?(String) ? "#{line}\n" : "#{JSON.generate(line)}\n"
            end.join)
          end
        end
      end
      env = { "GITHUB_STEP_SUMMARY" => summary }
      output, status = Open3.capture2e(env, RbConfig.ruby, script, *args, *paths, stdin_data: "")
      [status.success?, output]
    end
  end

  def line(counts, samples = [])
    { pid: 1, counts: counts, stale: { rule: { "dependency_reads" => 2 } }, samples: samples }
  end

  it "passes reports that each checked would-be hits and found no mismatch, and sums them" do
    expect(judge([line({ rule: { checked: 3 } })], [line({ main: { checked: 2 } })]))
      .to match([true, /stale rule: dependency_reads=4.*OK: 5 would-be hits checked/m])
  end

  it "fails a mismatch on any line, a missing or empty report, and a report that checked nothing" do
    expect(judge([line({ rule: { checked: 3 } }), line({ rule: { checked: 1, mismatch: 1 } }, [{ kinds: ["type"] }])]))
      .to match([false, /mismatch: `\{"kinds":\["type"\]\}`.*1 mismatch/m])
    expect(judge(nil)).to match([false, /no report written/])
    expect(judge([])).to match([false, /empty report/])
  end

  # Each run's report is held to its own check, so a run that dropped out cannot hide behind another.
  it "fails a report that checked nothing even when another report checked plenty" do
    expect(judge([line({ rule: { checked: 9 } })], [line({})])).to match([false, /report-1.jsonl: no would-be hit/])
  end

  it "fails a run whose exit status is above what it may exit with, and a call with no report" do
    ok = [line({ rule: { checked: 3 } })]

    expect(judge(ok, args: %w[--status lib=0:0 --status fixtures=1:1])).to match([true, /OK/])
    expect(judge(ok, args: %w[--status fixtures=2:1])).to match([false, /the fixtures run exited 2/])
    expect(judge).to match([false, /no report given/])
  end

  it "fails an unreadable line instead of crashing, and still writes the summary" do
    Dir.mktmpdir do |dir|
      summary = File.join(dir, "summary.md")
      passed, output = judge([line({ rule: { checked: 3 } }), '{"pid":2,"coun'], summary: summary)

      expect([passed, output]).to match([false, /report-0.jsonl:2: unreadable report line/])
      expect(File.read(summary)).to include("### ADR-129 type_of shadow", "FAIL:")
    end
  end
end
