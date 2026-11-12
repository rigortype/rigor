# frozen_string_literal: true

# Gates `agents/pi-harness/scripts/land-when-green.sh`, which marks a reviewed PR ready, waits for the full
# run's "CI required" (read through `bin/ci-required`, the rule `bin/land-pr` reads), holds on an advisory
# warning, and hands the PR to `bin/land-pr`.
#
# As in land_pr_spec.rb, a stand-in `gh` first on PATH answers each call with the next scripted reply (already
# in the `--jq` output shape asked for) and logs its arguments. The shipped script runs the shipped
# `bin/ci-required` and `bin/land-pr`, which call the same stand-in. LAND_WAIT_INTERVAL=0 and LAND_PR_INTERVAL=0
# make both polling loops run without sleeping.

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "agents/pi-harness/scripts/land-when-green.sh" do
  let(:script) { File.expand_path("../../agents/pi-harness/scripts/land-when-green.sh", __dir__) }
  let(:root) { Dir.mktmpdir("land-when-green") }
  let(:sha) { "a" * 40 }

  after { FileUtils.rm_rf(root) }

  def run_script(replies:, minutes: 1)
    bin = File.join(root, "bin")
    FileUtils.mkdir_p(bin)
    replies.each_with_index do |(out, status), i|
      File.write(File.join(root, "reply-#{i}"), "#{out}\n")
      File.write(File.join(root, "status-#{i}"), status.to_s)
    end
    File.write(File.join(bin, "gh"), <<~SH)
      #!/usr/bin/env bash
      n=$(cat "#{root}/count" 2>/dev/null || echo 0)
      echo $((n + 1)) > "#{root}/count"
      printf '%s\\n' "$*" >> "#{root}/calls"
      [[ -f "#{root}/reply-$n" ]] || exit 1
      if [[ "$(cat "#{root}/status-$n")" == 0 ]]; then cat "#{root}/reply-$n"; else cat "#{root}/reply-$n" >&2; fi
      exit "$(cat "#{root}/status-$n")"
    SH
    FileUtils.chmod(0o755, File.join(bin, "gh"))
    env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "LAND_WAIT_INTERVAL" => "0", "LAND_PR_INTERVAL" => "0",
            "LAND_WAIT_MINUTES" => minutes.to_s }
    out, status = Open3.capture2e(env, script, "42", sha, stdin_data: "")
    [out, status.exitstatus]
  end

  def calls
    File.exist?(File.join(root, "calls")) ? File.read(File.join(root, "calls")) : ""
  end

  def readied?
    calls.lines.any? { |line| line.start_with?("pr ready") }
  end

  def enqueued?
    calls.include?("enqueuePullRequest")
  end

  # One poll: the head, then the head's "CI required" check runs (<id> <conclusion> <check suite>).
  def poll(*runs, head: sha)
    [[head, 0], [runs.join("\n"), 0]]
  end

  # The head read and `gh pr ready` that open every run past the first check.
  def start
    [[sha, 0], ["", 0]]
  end

  # bin/land-pr's own calls once handed over: its PR read, its CI read, the enqueue and a merged poll.
  def land(runs)
    [[["PR_id", false, "OPEN", true, false, "master", sha].join("\t"), 0], [runs, 0], ["queued", 0],
     [["MERGED", false, "b" * 40].join("\t"), 0]]
  end

  it "waits through the draft's SKIPPED and a pending full run, then lands on SUCCESS" do
    replies = start + poll("7 skipped 1") + poll("7 skipped 1", "12 null 2") + poll("7 skipped 1", "12 success 2") +
              [["", 0]] + land("12 success 2")
    out, code = run_script(replies: replies)
    expect([code, readied?, enqueued?]).to eq([0, true, true])
    expect(out).to include("merged as #{'b' * 40}")
  end

  it "lands when an older FAILURE (a cancelled draft run's) sits beside a newer SUCCESS" do
    replies = start + poll("7 failure 1", "12 success 2") + [["", 0]] + land("7 failure 1\n12 success 2")
    _, code = run_script(replies: replies)
    expect([code, enqueued?]).to eq([0, true])
  end

  # Run 43285398874: a draft run cancelled by a newer push concluded its CI required CANCELLED.
  it "keeps waiting through a cancelled draft run's CANCELLED, then lands on SUCCESS" do
    replies = start + poll("7 cancelled 1") + poll("7 cancelled 1", "12 success 2") + [["", 0]] +
              land("7 cancelled 1\n12 success 2")
    _, code = run_script(replies: replies)
    expect([code, enqueued?]).to eq([0, true])
  end

  it "stops with exit 4 when the newest CI required failed" do
    out, code = run_script(replies: start + poll("7 skipped 1", "12 failure 2"))
    expect([code, enqueued?]).to eq([4, false])
    expect(out).to include('"CI required" is FAILURE')
  end

  it "stops with exit 3 and does not mark the PR ready when the head already moved" do
    out, code = run_script(replies: [["c" * 40, 0]])
    expect([code, readied?]).to eq([3, false])
    expect(out).to include("head moved")
  end

  it "stops with exit 3 when the head moves while it waits" do
    _, code = run_script(replies: start + poll("7 skipped 1", head: "c" * 40))
    expect([code, enqueued?]).to eq([3, false])
  end

  it "stops with exit 1 and does not mark the PR ready when the first read fails" do
    out, code = run_script(replies: [["HTTP 502", 1]])
    expect([code, readied?]).to eq([1, false])
    expect(out).to include("cannot read #42")
  end

  it "stops with exit 5 when the wait runs out" do
    out, code = run_script(replies: start + poll("7 skipped 1"), minutes: 0)
    expect([code, readied?, enqueued?]).to eq([5, true, false])
    expect(out).to include("still pending after the wait")
  end

  it "holds with exit 6, naming the run, when an advisory job of the passing run warns" do
    { "Engine allocations" => "https://example.test/job/31",
      "type_of shadow (ADR-129 G1)" => "https://example.test/job/32" }.each do |title, url|
      FileUtils.rm_f(Dir.glob(File.join(root, "*")))
      replies = start + poll("12 success 2") + [["31 #{url}", 0], [title, 0]]
      out, code = run_script(replies: replies)
      expect([title, code, enqueued?]).to eq([title, 6, false])
      expect(out).to include("advisory job warns", "#{title}: #{url}")
      expect(calls).to include("select(.check_suite.id == 2)", "check-runs/31/annotations")
    end
  end

  it "holds with exit 6 when the advisory results cannot be read" do
    out, code = run_script(replies: start + poll("12 success 2") + [["HTTP 502", 1]])
    expect([code, enqueued?]).to eq([6, false])
    expect(out).to include("cannot read the advisory results")
  end
end
