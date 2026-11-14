# frozen_string_literal: true

# Gates the intake refusals of `agents/pi-harness/scripts/takt-enqueue.sh`: the unlanded cap, and the
# claims that stop a second lane taking an issue another one already holds.
#
# As in land_when_green_spec.rb, a stand-in `gh` first on PATH answers each call with the next scripted
# reply (already in the `--jq` output shape asked for) and logs its arguments. The script is copied into
# a throwaway tree, because it derives the repository it reads `.takt/tasks.yaml` from, and the
# repository it asks `gh` about, from its own path. No example reaches `takt_enqueue_task`: a refusal
# exits before the enqueue, and an example that clears the gates is given an empty stand-in for
# takt-mcp, which ends the run there; it is asserted on the absence of a refusal.

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "agents/pi-harness/scripts/takt-enqueue.sh" do
  let(:source) { File.expand_path("../../agents/pi-harness/scripts/takt-enqueue.sh", __dir__) }
  let(:root) { Dir.mktmpdir("takt-enqueue") }
  let(:repo) { File.join(root, "repo") }
  let(:script) { File.join(repo, "agents", "pi-harness", "scripts", "takt-enqueue.sh") }

  after { FileUtils.rm_rf(root) }

  # One `tasks.yaml` entry, in the shape takt writes.
  def task(issue, status)
    <<~YAML
      - worktree: true
          branch: takt/#{issue}/implement-github-issue-#{issue}-as
          issue: #{issue}
          name: implement-github-issue-#{issue}-as
          status: #{status}
    YAML
  end

  # `tasks: ` plus the entries, or no file at all when none are given.
  def tasks_yaml(*entries)
    FileUtils.mkdir_p(File.join(repo, ".takt"))
    return if entries.empty?

    File.write(File.join(repo, ".takt", "tasks.yaml"), (["tasks:\n"] + entries).join)
  end

  # The claim table `gh pr list` answers with: each line an issue and the open PR that claims it.
  def claims(*pairs)
    pairs.map { |issue, pr| "#{issue}\t#{pr}" }.join("\n")
  end

  # A stand-in `gh` first on PATH, answering each call with the next reply and logging its arguments.
  def stub_gh(replies)
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
    bin
  end

  # The script in its own tree, with an empty stand-in for takt-mcp, so a run that clears the gates
  # ends at the enqueue rather than reaching takt.
  def run_script(*issues, replies:)
    bin = stub_gh(replies)
    FileUtils.mkdir_p(File.dirname(script))
    FileUtils.cp(source, script)
    FileUtils.chmod(0o755, script)
    mcp = File.join(root, "mcp.js")
    File.write(mcp, "")
    env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "TAKT_MCP" => mcp }
    out, status = Open3.capture2e(env, script, *issues.map(&:to_s), stdin_data: "")
    [out, status.exitstatus]
  end

  def calls
    File.exist?(File.join(root, "calls")) ? File.read(File.join(root, "calls")) : ""
  end

  # The open-PR count the unlanded cap reads, then the claim table.
  def gates(count: 0, claimed: "")
    [[count.to_s, 0], [claimed, 0]]
  end

  it "refuses an issue an open PR already closes" do
    tasks_yaml
    out, code = run_script(2783, replies: gates(claimed: claims([2783, 3159])))
    expect([code, calls.include?("issue view")]).to eq([4, false])
    expect(out).to include("#2783 is already claimed by open PR #3159")
  end

  it "refuses an issue an open takt branch is named for" do
    tasks_yaml
    out, code = run_script(1619, replies: gates(claimed: claims([1619, 3140])))
    expect(code).to eq(4)
    expect(out).to include("claimed by open PR #3140")
  end

  it "refuses an issue a queued task already holds" do
    tasks_yaml(task(2586, "pending"))
    out, code = run_script(2586, replies: gates)
    expect([code, calls.include?("issue view")]).to eq([4, false])
    expect(out).to include("#2586 is already a queued or running takt task")
  end

  it "refuses an issue a running task already holds" do
    tasks_yaml(task(3056, "running"))
    _, code = run_script(3056, replies: gates)
    expect(code).to eq(4)
  end

  it "refuses the same issue listed twice in one call" do
    tasks_yaml
    out, code = run_script(2586, 2586, replies: gates)
    expect(code).to eq(4)
    expect(out).to include("#2586 is listed twice")
  end

  it "takes an issue whose only task has finished" do
    tasks_yaml(task(1475, "completed"))
    out, = run_script(1475, replies: gates)
    expect(out).not_to match(/already claimed|already a queued|listed twice|TAKT_MAX_UNLANDED/)
  end

  it "takes an issue no PR claims and no unfinished task holds" do
    tasks_yaml(task(2586, "pending"))
    out, = run_script(3071, replies: gates(claimed: claims([2783, 3159])))
    expect(out).not_to match(/already claimed|already a queued|listed twice|TAKT_MAX_UNLANDED/)
    expect(calls.scan("pr list").length).to eq(2)
  end

  it "refuses to add to work already unlanded" do
    tasks_yaml
    out, code = run_script(3071, replies: [["5", 0]])
    expect([code, calls.include?("issue view")]).to eq([3, false])
    expect(out).to include("TAKT_MAX_UNLANDED")
  end
end
