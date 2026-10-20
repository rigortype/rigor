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
  def info(draft: false, state: "OPEN", queue: true, queued: false, head: sha, check: "SUCCESS", checked: head)
    ["PR_id", draft, state, queue, queued, "master", head, check, checked].join("\t")
  end

  def poll(state, queued: false, oid: "")
    [state, queued, oid].join("\t")
  end

  # Each reply is [stdout, exit status]; calls past the last reply fail.
  def run_land_pr(*, replies:, env: {})
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
    env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "LAND_PR_INTERVAL" => "0" }.merge(env)
    out, status = Open3.capture2e(env, script, *, stdin_data: "")
    [out, status.exitstatus]
  end

  def calls
    File.exist?(File.join(root, "calls")) ? File.read(File.join(root, "calls")) : ""
  end

  def enqueued?
    calls.include?("enqueuePullRequest") || calls.include?("merge-async")
  end

  def stacked_refusal
    "This pull request is part of a stack and must be enqueued using the asynchronous merge REST API."
  end

  # The merge-async reply is the raw JSON body; a 409 is the same body after its "HTTP 409" line.
  def async_body(status, uuid: "u-1", action: "merge_queue")
    %({"status":"#{status}","details":{"message":"ok","uuid":"#{uuid}","merge_action":"#{action}"}})
  end

  def conflict_body(action: "merge_queue", uuid: "u-9")
    "gh: merge already pending (HTTP 409)\n#{async_body('pending', uuid: uuid, action: action)}"
  end

  it "requests a native-stack PR through the merge-async REST endpoint once GraphQL refuses it" do
    out, code = run_land_pr("42", sha, "--no-wait",
                            replies: [[info, 0], [stacked_refusal, 1], [async_body("pending"), 0]])
    expect(code).to eq(0)
    expect(out).to include("native stack", "merge requested (pending)", "request u-1")
    expect(out).not_to include("queued")
    rest_call = calls.lines.grep(/merge-async/).first.to_s
    expect(rest_call).to include("-X PUT repos/rigortype/rigor/pulls/42/merge-async", "-f sha=#{sha}",
                                 "-f merge_action=merge_queue")
  end

  it "waits for a native-stack PR requested through merge-async until it merges" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], [stacked_refusal, 1], [async_body("pending"), 0],
                                                 [poll("MERGED", oid: "b" * 40), 0]])
    expect(code).to eq(0)
    expect(out).to include("merged as #{'b' * 40}")
  end

  it "reports a merge-async request that is already in the queue as such" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], [stacked_refusal, 1],
                                                 [async_body("enqueued", uuid: "u-2"), 0],
                                                 [poll("MERGED", oid: "b" * 40), 0]])
    expect(code).to eq(0)
    expect(out).to include("already in the merge queue", "u-2")
  end

  it "reports a merge-async request that is already merged as such" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], [stacked_refusal, 1],
                                                 [async_body("merged", uuid: "u-3"), 0],
                                                 [poll("MERGED", oid: "b" * 40), 0]])
    expect(code).to eq(0)
    expect(out).to include("already merged", "u-3")
  end

  it "waits for a 409 whose pending request is for the merge queue" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], [stacked_refusal, 1], [conflict_body, 1],
                                                 [poll("MERGED", oid: "b" * 40), 0]])
    expect(code).to eq(0)
    expect(out).to include("already has a merge request pending at #{sha}, request u-9; waiting")
  end

  it "refuses a 409 whose pending request uses another merge action, without waiting" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], [stacked_refusal, 1],
                                                 [conflict_body(action: "direct_merge"), 1]])
    expect(code).to eq(1)
    expect(out).to include("uses direct_merge, not the merge queue; refusing to endorse it")
    expect(out).not_to include("waiting")
  end

  it "reports a refusal from merge-async with GitHub's reply, without waiting" do
    out, code = run_land_pr("42", sha, "--no-wait", replies: [[info, 0], [stacked_refusal, 1], ["draft", 1]])
    expect(code).to eq(1)
    expect(out).to include("through the merge-async API: draft")
  end

  it "dies when merge-async accepts the request and reports it failed" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], [stacked_refusal, 1], [async_body("failed"), 0]])
    expect([code, enqueued?]).to eq([1, true])
    expect(out).to include("failed the merge-async request")
    expect(out).not_to include("unreadable")
  end

  it "keeps polling while the merge-async request is pending, then waits for the merge" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], [stacked_refusal, 1], [async_body("pending"), 0],
                                                 [poll("OPEN"), 0], [poll("OPEN"), 0],
                                                 ["pending waiting for checks", 0],
                                                 [poll("OPEN", queued: true), 0],
                                                 [poll("MERGED", oid: "b" * 40), 0]])
    expect(code).to eq(0)
    expect(out).to include("merged as #{'b' * 40}")
    expect(calls).to include('"\(.status) \(.details.message // "")"')
  end

  it "gives up with the request's status once a pending request passes the bound" do
    replies = [[info, 0], [stacked_refusal, 1], [async_body("pending"), 0],
               [poll("OPEN"), 0], [poll("OPEN"), 0], ["pending waiting for checks", 0]]
    out, code = run_land_pr("42", sha, env: { "LAND_PR_PENDING_LIMIT" => "0" }, replies: replies)
    expect(code).to eq(1)
    expect(out).to include("merge-async request u-1 is still pending after 0 minutes", "waiting for checks")
  end

  # A stub `date` ticks one second per call (100, 101, ...), so the bound is crossed between two
  # pending reads. A watch that restarted the clock on every read would never reach it.
  def stub_clock
    bin = File.join(root, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "date"), <<~SH)
      #!/usr/bin/env bash
      n=$(cat "#{root}/clock" 2>/dev/null || echo 0)
      echo $((n + 1)) > "#{root}/clock"
      echo $((100 + n))
    SH
    FileUtils.chmod(0o755, File.join(bin, "date"))
  end

  it "stops polling once the pending clock, started at the first pending read, passes the bound" do
    stub_clock
    replies = [[info, 0], [stacked_refusal, 1], [async_body("pending"), 0],
               [poll("OPEN"), 0], [poll("OPEN"), 0], ["pending waiting for checks", 0],
               [poll("OPEN"), 0], [poll("OPEN"), 0], ["pending waiting for checks", 0]]
    out, code = run_land_pr("42", sha, env: { "LAND_PR_PENDING_LIMIT" => "1" }, replies: replies)
    expect(code).to eq(1)
    expect(out).to include("merge-async request u-1 is still pending after 0 minutes")
    expect(File.read(File.join(root, "count")).to_i).to eq(9)
  end

  it "keeps polling while the request reads merged until the PR merges" do
    replies = [[info, 0], [stacked_refusal, 1], [async_body("pending"), 0],
               [poll("OPEN"), 0], [poll("OPEN"), 0], ["merged", 0],
               [poll("OPEN", queued: true), 0], [poll("MERGED", oid: "b" * 40), 0]]
    out, code = run_land_pr("42", sha, replies: replies)
    expect(code).to eq(0)
    expect(out).to include("merged as #{'b' * 40}")
  end

  it "refuses a 2xx reply whose status it cannot parse, and says the request may still be accepted" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], [stacked_refusal, 1], ["{}", 0]])
    expect(code).to eq(1)
    expect(out).to include("could not read the merge-async reply", "may still have been accepted")
  end

  it "refuses when the request reads enqueued but the PR is not in the queue" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], [stacked_refusal, 1], [async_body("pending"), 0],
                                                 [poll("OPEN"), 0], [poll("OPEN"), 0], ["enqueued ", 0]])
    expect(code).to eq(1)
    expect(out).to include("is not in the queue, but merge-async request u-1 reads enqueued")
  end

  it "names the merge-async request when a requested PR never reaches the queue" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], [stacked_refusal, 1], [async_body("pending"), 0],
                                                 [poll("OPEN"), 0], [poll("OPEN"), 0],
                                                 ["failed Merge conflict", 0]])
    expect(code).to eq(1)
    expect(out).to include("is not queued or merged", "merge-async request u-1 is failed",
                           "(Merge conflict)")
    expect(calls).to include("merge-async/u-1")
  end

  it "dies when the merge-async request cannot be read" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], [stacked_refusal, 1], [async_body("pending"), 0],
                                                 [poll("OPEN"), 0], [poll("OPEN"), 0], ["HTTP 500", 1]])
    expect(code).to eq(1)
    expect(out).to include("cannot be read")
  end

  it "prints the queue position GraphQL reports for an ordinary queue" do
    out, code = run_land_pr("42", sha, "--no-wait",
                            replies: [[info, 0], ["land-pr: #42 queued at #{sha}, position 3", 0]])
    expect(code).to eq(0)
    expect(out).to include("queued at #{sha}, position 3")
    expect(calls).to include('position \(.data.enqueuePullRequest.mergeQueueEntry.position)')
  end

  it "does not fall back to merge-async for a GraphQL refusal that is not the stacked one" do
    out, code = run_land_pr("42", sha, "--no-wait", replies: [[info, 0], ["Resource not accessible", 1]])
    expect(code).to eq(1)
    expect(out).to include("GitHub refused to queue #42", "Resource not accessible")
    expect(calls).not_to include("merge-async")
  end

  it "queues the reviewed head, passing it as the expected head, and reports the merge commit" do
    out, code = run_land_pr("42", sha, replies: [[info, 0], ["queued", 0], [poll("MERGED", oid: "b" * 40), 0]])
    expect(code).to eq(0)
    expect(out).to include("merged as #{'b' * 40}")
    expect(calls).to match(/enqueuePullRequest.*expectedHeadOid/)
    expect(calls).to include("sha=#{sha}")
  end

  it "reads CI required from the head commit and the PR's fields by name" do
    run_land_pr("42", sha, "--no-wait", replies: [[info, 0], ["queued", 0]])
    expect(calls).to include("statusCheckRollup", 'select(.name == "CI required")', "headRefOid", "isMergeQueueEnabled")
  end

  it "refuses when the green check belongs to a commit other than the head, before queueing" do
    _, code = run_land_pr("42", sha, replies: [[info(checked: "d" * 40), 0]])
    expect([code, enqueued?]).to eq([1, false])
  end

  it "refuses a head other than the reviewed one, before queueing" do
    out, code = run_land_pr("42", sha, replies: [[info(head: "c" * 40), 0]])
    expect([code, enqueued?]).to eq([1, false])
    expect(out).to include("not the reviewed")
  end

  it "refuses a PR whose base is not master, before queueing, so the bottom PR lands first" do
    reply = ["PR_id", false, "OPEN", true, false, "parent-branch", sha, "SUCCESS", sha].join("\t")
    out, code = run_land_pr("42", sha, replies: [[reply, 0]])
    expect([code, enqueued?]).to eq([1, false])
    expect(out).to include("land the bottom PR of its stack first")
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
