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
  let(:alloc_job) { "Engine allocations (advisory)" }
  let(:shadow_job) { "Acceptance gates (cold analysis)" }

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
    [[["PR_id", false, "OPEN", true, false, "master", sha, "topic"].join("\t"), 0], [runs, 0], ["queued", 0],
     [["MERGED", false, "b" * 40].join("\t"), 0]]
  end

  # The head's check runs as the advisory read lists them (suite, id, status, conclusion, url, name, tab-separated),
  # then one annotation-title reply per advisory job that concluded success. The same names in an older suite
  # (1, failed) must be ignored.
  def advisory(alloc: %w[completed success], shadow: %w[completed success], titles: {}, jobs: [alloc_job, shadow_job])
    verdicts = { alloc_job => alloc, shadow_job => shadow }
    ids = { alloc_job => 31, shadow_job => 32 }
    rows = jobs.map { |job| ["2", ids[job], *verdicts[job], "https://example.test/job/#{ids[job]}", job].join("\t") }
    rows += [alloc_job, shadow_job].map { |job| ["1", 9, "completed", "failure", "https://example.test/old", job].join("\t") }
    rows << ["2", 33, "completed", "success", "https://example.test/job/33", "Lint"].join("\t")
    [[rows.join("\n"), 0]] +
      jobs.select { |job| verdicts[job] == %w[completed success] }.map { |job| [titles.fetch(job, ""), 0] }
  end

  it "waits through the draft's SKIPPED and a pending full run, then lands on SUCCESS" do
    replies = start + poll("7 skipped 1") + poll("7 skipped 1", "12 null 2") + poll("7 skipped 1", "12 success 2") +
              advisory + land("12 success 2")
    out, code = run_script(replies: replies)
    expect([code, readied?, enqueued?]).to eq([0, true, true])
    expect(out).to include("merged as #{'b' * 40}")
  end

  it "lands when an older FAILURE (a cancelled draft run's) sits beside a newer SUCCESS" do
    replies = start + poll("7 failure 1", "12 success 2") + advisory + land("7 failure 1\n12 success 2")
    _, code = run_script(replies: replies)
    expect([code, enqueued?]).to eq([0, true])
  end

  # Run 43285398874: a draft run cancelled by a newer push concluded its CI required CANCELLED.
  it "keeps waiting through a cancelled draft run's CANCELLED, then lands on SUCCESS" do
    replies = start + poll("7 cancelled 1") + poll("7 cancelled 1", "12 success 2") + advisory +
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
    { alloc_job => ["Engine allocations", 31], shadow_job => ["type_of shadow (ADR-129 G1)", 32] }
      .each do |job, (title, id)|
      FileUtils.rm_f(Dir.glob(File.join(root, "*")))
      replies = start + poll("12 success 2") + advisory(titles: { job => "Ubuntu notice\n#{title}" })
      out, code = run_script(replies: replies)
      expect([title, code, enqueued?]).to eq([title, 6, false])
      expect(out).to include("advisory job holds", %(#{job} warns "#{title}": https://example.test/job/#{id}))
      expect(calls).to include("check-runs/31/annotations", "check-runs/32/annotations")
    end
  end

  it "lands past the cumulative Release gate allocations warning, which is not a hold" do
    replies = start + poll("12 success 2") +
              advisory(titles: { alloc_job => "Release gate allocations" }) + land("12 success 2")
    _, code = run_script(replies: replies)
    expect([code, enqueued?]).to eq([0, true])
  end

  it "lands when both advisory jobs were skipped, as on a no-code PR" do
    replies = start + poll("12 success 2") +
              advisory(alloc: %w[completed skipped], shadow: %w[completed skipped]) + land("12 success 2")
    _, code = run_script(replies: replies)
    expect([code, enqueued?]).to eq([0, true])
  end

  it "holds with exit 6 when an advisory job of the passing run has no verdict" do
    [{ alloc: %w[completed failure] }, { alloc: %w[completed timed_out] }, { shadow: %w[completed cancelled] },
     { jobs: [shadow_job] }].each do |shape|
      FileUtils.rm_f(Dir.glob(File.join(root, "*")))
      out, code = run_script(replies: start + poll("12 success 2") + advisory(**shape))
      expect([shape, code, enqueued?]).to eq([shape, 6, false])
      expect(out).to match(/has no verdict|has no check run/)
    end
  end

  it "waits for an advisory job still running, then lands" do
    replies = start + poll("12 success 2") + advisory(alloc: %w[in_progress null]) +
              poll("12 success 2") + advisory + land("12 success 2")
    _, code = run_script(replies: replies)
    expect([code, enqueued?]).to eq([0, true])
  end

  it "holds with exit 6 when an advisory job is still pending as the wait runs out" do
    out, code = run_script(replies: start + poll("12 success 2") + advisory(shadow: %w[queued null]), minutes: 0)
    expect([code, enqueued?]).to eq([6, false])
    expect(out).to include("advisory jobs are still pending")
  end

  # The script matches advisory jobs and warnings by literal; a rename at the source must fail here, not open the
  # hold. Each literal is read from the script and found in the file that emits it.
  it "matches the advisory job names and warning titles their sources emit" do
    source = File.read(script)
    literal = ->(var) { source[/^#{var}="([^"]+)"$/, 1] }
    ci = File.read(File.expand_path("../../.github/workflows/ci.yml", __dir__))
    alloc_ab = File.read(File.expand_path("../../tool/engine_alloc_ab.rb", __dir__))
    expect(ci).to include("    name: #{literal['ALLOC_JOB']}\n", "    name: #{literal['SHADOW_JOB']}\n")
    expect(alloc_ab).to include("::warning title=#{literal['ALLOC_TITLE']}::")
    expect(ci).to match(/::warning title=#{Regexp.escape(literal['SHADOW_TITLE_PREFIX'])}[^:]*::/)
    expect([literal["ALLOC_JOB"], literal["SHADOW_JOB"]]).to eq([alloc_job, shadow_job])
  end

  it "holds with exit 6 when the advisory results cannot be read" do
    out, code = run_script(replies: start + poll("12 success 2") + [["HTTP 502", 1]])
    expect([code, enqueued?]).to eq([6, false])
    expect(out).to include("cannot read the advisory results")
  end
end
