# frozen_string_literal: true

# The report selection in front of CI's `shard-coverage` job (`tool/shard_report_select.rb`).
#
# The job exists to catch shards that partitioned different timing data, and run 35844873791 showed it
# passing exactly that case: a "Re-run failed jobs" attempt re-ran shard 2 under a newer timing cache, and
# the fan-in checked attempt 1's stale shard-2 report instead. These pin the two rules that close it — the
# newest attempt per shard is the one checked, and chosen shards must share one timing file — because a
# regression in either still prints a plausible "3 shards cover all N tests".
#
# Unit test only: requiring the script defines {ShardReportSelect} without running it.
require "json"
require "tmpdir"
require "spec_helper"

require_relative "../../tool/shard_report_select"

RSpec.describe "tool/shard_report_select.rb" do
  let(:root) { Dir.mktmpdir("shard-report-select") }
  let(:downloads) { File.join(root, "reports") }
  let(:selected) { File.join(root, "selected") }

  after { FileUtils.rm_rf(root) }

  # Lays out one artifact the way download-artifact does without `merge-multiple`.
  def artifact(shard:, attempt:, timings:, report: { "selected_tests" => 1 })
    dir = File.join(downloads, "binpacker-report-#{shard}-attempt-#{attempt}")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "binpacker-provenance-#{shard}.json"),
               JSON.generate("shard" => shard, "run_attempt" => attempt, "timings_sha256" => timings))
    File.write(File.join(dir, "binpacker-report-#{shard}.json"), JSON.generate(report)) if report
    dir
  end

  describe ".choose" do
    it "takes each shard's newest attempt when every shard cut from one timing file" do
      artifact(shard: 1, attempt: 1, timings: "aaa")
      artifact(shard: 2, attempt: 1, timings: "aaa")
      rerun = artifact(shard: 2, attempt: 2, timings: "aaa")
      artifact(shard: 3, attempt: 1, timings: "aaa")

      chosen = ShardReportSelect.choose(downloads)

      expect(chosen.map { |p| [p.shard, p.attempt] }).to eq([[1, 1], [2, 2], [3, 1]])
      expect(chosen.find { |p| p.shard == 2 }.dir).to eq(rerun)
    end

    # Run 35844873791: the re-run shard restored the timing cache its passed siblings saved.
    it "refuses a partial rerun whose shard restored a different timing file" do
      artifact(shard: 1, attempt: 1, timings: "aaa")
      artifact(shard: 2, attempt: 1, timings: "aaa")
      artifact(shard: 2, attempt: 2, timings: "bbb")
      artifact(shard: 3, attempt: 1, timings: "aaa")

      expect { ShardReportSelect.choose(downloads) }
        .to raise_error(ShardReportSelect::Error, /different timing files.*shard 2: attempt 2, timings bbb/m)
    end

    it "refuses shards of one attempt that restored different timing files" do
      artifact(shard: 1, attempt: 1, timings: "aaa")
      artifact(shard: 2, attempt: 1, timings: "bbb")

      expect { ShardReportSelect.choose(downloads) }.to raise_error(ShardReportSelect::Error, /different timing files/)
    end

    it "accepts a cold start, where no shard restored a timing file" do
      artifact(shard: 1, attempt: 1, timings: "absent")
      artifact(shard: 2, attempt: 1, timings: "absent")

      expect(ShardReportSelect.choose(downloads).size).to eq(2)
    end

    it "refuses a download with no provenance records" do
      FileUtils.mkdir_p(File.join(downloads, "binpacker-report-1"))

      expect { ShardReportSelect.choose(downloads) }.to raise_error(ShardReportSelect::Error, /no shard provenance/)
    end

    it "refuses a malformed provenance record" do
      dir = File.join(downloads, "binpacker-report-1-attempt-1")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "binpacker-provenance-1.json"), JSON.generate("shard" => "1"))

      expect { ShardReportSelect.choose(downloads) }.to raise_error(ShardReportSelect::Error, /expected integer shard/)
    end
  end

  describe ".stage" do
    it "copies the chosen attempt's report, not an earlier attempt's" do
      artifact(shard: 1, attempt: 1, timings: "aaa", report: { "selected_tests" => 168 })
      artifact(shard: 1, attempt: 2, timings: "aaa", report: { "selected_tests" => 169 })

      ShardReportSelect.stage(ShardReportSelect.choose(downloads), selected)

      expect(Dir.children(selected)).to eq(["binpacker-report-1.json"])
      expect(JSON.parse(File.read(File.join(selected, "binpacker-report-1.json")))).to eq("selected_tests" => 169)
    end

    it "refuses a chosen attempt that uploaded no run report rather than falling back to an older one" do
      artifact(shard: 1, attempt: 1, timings: "aaa")
      artifact(shard: 1, attempt: 2, timings: "aaa", report: nil)

      expect { ShardReportSelect.stage(ShardReportSelect.choose(downloads), selected) }
        .to raise_error(ShardReportSelect::Error, /shard 1 attempt 2 uploaded no run report/)
    end
  end

  describe ".main" do
    it "exits non-zero with the reason on stderr" do
      artifact(shard: 1, attempt: 1, timings: "aaa")
      artifact(shard: 2, attempt: 1, timings: "bbb")

      expect { expect(ShardReportSelect.main([downloads, selected])).to eq(1) }
        .to output(/shard report selection failed: the shards partitioned different timing files/).to_stderr
    end
  end
end
