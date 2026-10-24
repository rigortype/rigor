# frozen_string_literal: true

# Gates `bin/lane-push`, the one push path the lane contract allows (.claude/skills/rigor-lane/SKILL.md).
#
# Each example runs the shipped script in a scratch clone of a scratch bare remote, with a stand-in
# `bin/verify-changed` whose exit status the example chooses. The clone sets `push.default=tracking`, the
# host setting that turns a bare `git push` of a branch cut from origin/master into a push onto master, so the
# first example also proves the explicit refspec. The refusals are asserted on the remote's refs, not on the
# script's messages: a refusal that still pushed is the defect.

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "bin/lane-push" do
  let(:script) { File.expand_path("../../bin/lane-push", __dir__) }
  let(:root) { Dir.mktmpdir("lane-push") }
  let(:remote) { File.join(root, "origin.git") }
  let(:work) { File.join(root, "work") }

  after { FileUtils.rm_rf(root) }

  def git(dir, *args)
    out, status = Bundler.with_unbundled_env { Open3.capture2e("git", *args, chdir: dir) }
    raise "git #{args.join(' ')} failed in #{dir}:\n#{out}" unless status.success?

    out.strip
  end

  def configure(dir)
    git(dir, "config", "user.name", "Lane Push Spec")
    git(dir, "config", "user.email", "lane-push@example.invalid")
    git(dir, "config", "push.default", "tracking")
  end

  def commit_file(dir, name, content)
    File.write(File.join(dir, name), content)
    git(dir, "add", name)
    git(dir, "commit", "--quiet", "-m", "Write #{name}")
    git(dir, "rev-parse", "HEAD")
  end

  # The stand-in gate runs `.verify-hook` when present (to act while lane-push is between its fetch and its
  # push) and exits with the status written in `.verify-exit`; both files are ignored, so neither dirties the
  # tree.
  def stand_in_gate
    <<~SH
      #!/usr/bin/env bash
      [[ -f .verify-hook ]] && bash .verify-hook
      exit "$(cat .verify-exit 2>/dev/null || echo 0)"
    SH
  end

  # A remote whose master holds the script and the stand-in gate, and a clone of it on branch `feature`.
  def set_up(branch: "feature")
    seed_remote
    git(root, "clone", "--quiet", remote, work)
    configure(work)
    git(work, "checkout", "--quiet", "-b", branch, "origin/master")
    commit_file(work, "change.txt", "one\n")
  end

  def seed_remote
    git(root, "init", "--quiet", "--bare", "--initial-branch=master", remote)
    seed = File.join(root, "seed")
    git(root, "clone", "--quiet", remote, seed)
    configure(seed)
    git(seed, "checkout", "--quiet", "-b", "master")
    FileUtils.mkdir_p(File.join(seed, "bin"))
    FileUtils.cp(script, File.join(seed, "bin/lane-push"))
    File.write(File.join(seed, "bin/verify-changed"), stand_in_gate)
    File.chmod(0o755, File.join(seed, "bin/verify-changed"))
    File.write(File.join(seed, ".gitignore"), ".verify-exit\n.verify-hook\n")
    git(seed, "add", ".")
    git(seed, "commit", "--quiet", "-m", "Seed")
    git(seed, "push", "--quiet", "origin", "HEAD:refs/heads/master")
  end

  def lane_push(*, dir: work)
    out, status = Bundler.with_unbundled_env { Open3.capture2e(File.join(work, "bin/lane-push"), *, chdir: dir) }
    [out, status.exitstatus]
  end

  def remote_ref(name)
    out, = Open3.capture2e("git", "rev-parse", "--verify", "--quiet", "refs/heads/#{name}", chdir: remote)
    out.strip.empty? ? nil : out.strip
  end

  def gate_exit(status) = File.write(File.join(work, ".verify-exit"), "#{status}\n")

  # A second clone that pushes `name` to master, as another PR landing would.
  def move_master(name, content)
    other = File.join(root, "master-mover")
    git(root, "clone", "--quiet", remote, other) unless File.directory?(other)
    configure(other)
    git(other, "pull", "--quiet", "--rebase", "origin", "master")
    sha = commit_file(other, name, content)
    git(other, "push", "--quiet", "origin", "HEAD:refs/heads/master")
    sha
  end

  it "pushes a new branch to its own ref and leaves master alone under push.default=tracking" do
    set_up
    master_before = remote_ref("master")
    out, status = lane_push(dir: File.join(work, "bin"))
    expect(status).to eq(0), out
    expect(remote_ref("feature")).to eq(git(work, "rev-parse", "HEAD"))
    expect(remote_ref("master")).to eq(master_before)
  end

  it "rebases onto the latest master and force-pushes the rewritten branch with a lease" do
    set_up
    lane_push
    other = File.join(root, "other")
    git(root, "clone", "--quiet", remote, other)
    configure(other)
    new_master = commit_file(other, "master.txt", "moved\n")
    git(other, "push", "--quiet", "origin", "HEAD:refs/heads/master")
    commit_file(work, "change.txt", "two\n")

    out, status = lane_push
    expect(status).to eq(0), out
    pushed = remote_ref("feature")
    expect(pushed).to eq(git(work, "rev-parse", "HEAD"))
    expect(git(work, "merge-base", "--is-ancestor", new_master, pushed)).to eq("")
  end

  it "pushes nothing when the gate fails, and pushes with the reason printed under --no-verify" do
    set_up
    gate_exit(1)
    out, status = lane_push
    expect(status).to eq(1)
    expect(remote_ref("feature")).to be_nil, out

    out, status = lane_push("--no-verify=#2021 predates the branch")
    expect(status).to eq(0), out
    expect(out).to include("#2021 predates the branch")
    expect(remote_ref("feature")).to eq(git(work, "rev-parse", "HEAD"))
  end

  # The review-round path: a rebase that lands, a gate that then fails, a fix committed on the rebased
  # branch. Its own earlier push is no longer an ancestor, and must not read as someone else's commit.
  it "pushes a fix after an earlier run rebased the branch and its gate failed" do
    set_up
    lane_push
    new_master = move_master("master.txt", "moved\n")
    gate_exit(1)
    expect(lane_push.last).to eq(1)
    gate_exit(0)
    commit_file(work, "change.txt", "fixed\n")

    out, status = lane_push
    expect(status).to eq(0), out
    expect(remote_ref("feature")).to eq(git(work, "rev-parse", "HEAD"))
    expect(git(work, "merge-base", "--is-ancestor", new_master, remote_ref("feature"))).to eq("")
  end

  it "pushes after a rebase conflict is resolved and continued, as its message says" do
    set_up
    lane_push
    move_master("change.txt", "master's line\n")
    out, status = lane_push
    expect(status).to eq(1)
    expect(out).to include("rebase --continue")

    File.write(File.join(work, "change.txt"), "resolved\n")
    git(work, "add", "change.txt")
    Bundler.with_unbundled_env do
      Open3.capture2e({ "GIT_EDITOR" => "true" }, "git", "rebase", "--continue", chdir: work)
    end
    out, status = lane_push
    expect(status).to eq(0), out
    expect(remote_ref("feature")).to eq(git(work, "rev-parse", "HEAD"))
  end

  it "loses the race to a writer who pushes the branch while the gate runs" do
    set_up
    lane_push
    theirs_dir = File.join(root, "theirs")
    git(root, "clone", "--quiet", "--branch", "feature", remote, theirs_dir)
    configure(theirs_dir)
    File.write(File.join(theirs_dir, "theirs.txt"), "fix-up\n")
    git(theirs_dir, "add", "theirs.txt")
    File.write(File.join(work, ".verify-hook"),
               "git -C #{theirs_dir} commit --quiet -m 'Fix up' && git -C #{theirs_dir} push --quiet origin " \
               "HEAD:refs/heads/feature\n")
    commit_file(work, "change.txt", "two\n")

    expect(lane_push.last).to eq(1)
    expect(remote_ref("feature")).to eq(git(theirs_dir, "rev-parse", "HEAD"))
  end

  it "refuses to drop a commit another writer pushed to the branch" do
    set_up
    lane_push
    other = File.join(root, "other")
    git(root, "clone", "--quiet", "--branch", "feature", remote, other)
    configure(other)
    theirs = commit_file(other, "theirs.txt", "fix-up\n")
    git(other, "push", "--quiet", "origin", "HEAD:refs/heads/feature")
    commit_file(work, "change.txt", "two\n")

    _, status = lane_push
    expect(status).to eq(1)
    expect(remote_ref("feature")).to eq(theirs)
  end

  it "refuses a dirty tree, an untracked file, master, and a tool-prefixed branch" do
    set_up
    File.write(File.join(work, "change.txt"), "uncommitted\n")
    expect(lane_push.last).to eq(1)
    git(work, "checkout", "--quiet", "--", "change.txt")

    # The gate reads the working tree, so a file the commit forgot would pass it and miss the push.
    File.write(File.join(work, "forgotten.rb"), "# never added\n")
    expect(lane_push.last).to eq(1)
    expect(remote_ref("feature")).to be_nil
    File.delete(File.join(work, "forgotten.rb"))

    git(work, "checkout", "--quiet", "-b", "Claude/some-task")
    expect(lane_push.last).to eq(1)
    expect(remote_ref("Claude/some-task")).to be_nil

    git(work, "checkout", "--quiet", "-B", "master", "origin/master")
    commit_file(work, "on-master.txt", "a lane commit on master\n")
    master_before = remote_ref("master")
    expect(lane_push.last).to eq(1)
    expect(remote_ref("master")).to eq(master_before)
    expect(remote_ref("feature")).to be_nil
  end
end
