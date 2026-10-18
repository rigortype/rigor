# frozen_string_literal: true

# Gates `bin/land-pr`, the one way a PR enters master's merge queue (ADR-123, contribution-flow.md).
#
# Each example runs the shipped script with a stand-in `gh` first on PATH. The stand-in answers each call
# with the next scripted reply (already in the `--jq` output shape the script asks for) and logs its
# arguments, so an example can assert that a refusal never reached the enqueue mutation: a refusal that
# still queued is the defect. LAND_PR_INTERVAL=0 makes the polling loop run without sleeping.

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "bin/land-pr" do
  let(:script) { File.expand_path("../../bin/land-pr", __dir__) }
  let(:root) { Dir.mktmpdir("land-pr") }
  let(:sha) { "a" * 40 }

  after { FileUtils.rm_rf(root) }

  # The PR as the first query reads it: id, draft, state, queue on master, queued, base, head, CI required.
  def info(draft: false, state: "OPEN", queue: true, queued: false, head: sha, check: "SUCCESS")
    ["PR_id", draft, state, queue, queued, "master", head, check].join("\t")
  end

  def poll(state, queued: false, oid: "")
    [state, queued, oid].join("\t")
  end

  # Each reply is [stdout, exit status]; calls past the last reply fail.
  def run_land_pr(*, replies:)
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
      cat "#{root}/reply-$n"
      exit "$(cat "#{root}/status-$n")"
    SH
    FileUtils.chmod(0o755, File.join(bin, "gh"))
    env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "LAND_PR_INTERVAL" => "0" }
    out, status = Open3.capture2e(env, script, *, stdin_data: "")
    [out, status.exitstatus]
  end

  def calls
    File.exist?(File.join(root, "calls")) ? File.read(File.join(root, "calls")) : ""
  end

  def enqueued?
    calls.include?("enqueuePullRequest")
  end

  it "queues the reviewed head, passing it as the expected head, and reports the merge commit" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], ["queued", 0], [poll("MERGED", oid: "b" * 40), 0]])
    expect(code).to eq(0)
    expect(out).to include("merged as #{'b' * 40}")
    expect(calls).to match(/enqueuePullRequest.*expectedHeadOid/)
    expect(calls).to include("sha=#{sha}")
  end

  it "refuses a head other than the reviewed one, before queueing" do
    out, code = run_land_pr("42", sha, replies: [[info(head: "c" * 40), 0]])
    expect([code, enqueued?]).to eq([1, false])
    expect(out).to include("not the reviewed")
  end

  it "refuses when CI required on the head has not passed, before queueing" do
    %w[FAILURE MISSING null].each do |ci|
      FileUtils.rm_f(Dir.glob(File.join(root, "*")))
      _, code = run_land_pr("42", sha, replies: [[info(check: ci), 0]])
      expect([ci, code, enqueued?]).to eq([ci, 1, false])
    end
  end

  it "refuses when master has no merge queue, a draft, or a closed PR, before queueing" do
    [{ queue: false }, { draft: true }, { state: "CLOSED" }].each do |shape|
      FileUtils.rm_f(Dir.glob(File.join(root, "*")))
      _, code = run_land_pr("42", sha, replies: [[info(**shape), 0]])
      expect([shape, code, enqueued?]).to eq([shape, 1, false])
    end
  end

  it "only waits when the PR is already queued" do
    out, code = run_land_pr("42", sha, replies: [[info(queued: true, check: "MISSING"), 0],
                                                 [poll("MERGED", oid: "b" * 40), 0]])
    expect([code, enqueued?]).to eq([0, false])
    expect(out).to include("already queued")
  end

  it "re-reads once before calling a PR dropped, so a lagging merge still reports merged" do
    _, code = run_land_pr("42", sha, replies: [[info, 0], ["queued", 0], [poll("OPEN"), 0],
                                               [poll("MERGED", oid: "b" * 40), 0]])
    expect(code).to eq(0)
  end

  it "reports a PR that stays out of the queue as dropped" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], ["queued", 0], [poll("OPEN"), 0], [poll("OPEN"), 0]])
    expect(code).to eq(1)
    expect(out).to include("left the queue unmerged")
  end

  it "waits for the merge commit when the state reads MERGED before it" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], ["queued", 0], [poll("MERGED"), 0],
                                                 [poll("MERGED", oid: "b" * 40), 0]])
    expect(code).to eq(0)
    expect(out).to include("merged as #{'b' * 40}")
  end

  it "gives up after ten unreadable polls in a row" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], ["queued", 0]])
    expect(code).to eq(1)
    expect(out).to include("unreadable for 10 polls")
    expect(File.read(File.join(root, "count")).to_i).to eq(12) # the read, the enqueue, then ten failed polls
  end

  it "returns once queued with --no-wait" do
    _, code = run_land_pr("42", sha, "--no-wait", replies: [[info, 0], ["queued", 0]])
    expect([code, enqueued?]).to eq([0, true])
  end

  it "rejects a missing SHA and a second number as usage errors" do
    expect(run_land_pr("42", replies: []).last).to eq(2)
    expect(run_land_pr("42", "43", replies: []).last).to eq(2)
    expect(calls).to be_empty
  end
end
