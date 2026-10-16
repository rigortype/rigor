# frozen_string_literal: true

# Gates `bin/lane-push`, the one push path the lane contract allows (docs/agents/parallel-lanes.md).
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

  # A remote whose master holds the script and a stand-in gate that exits with the status written in
  # `.verify-exit` (untracked, so it never dirties the tree), and a clone of it on branch `feature`.
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
    File.write(File.join(seed, "bin/verify-changed"),
               "#!/usr/bin/env bash\nexit \"$(cat .verify-exit 2>/dev/null || echo 0)\"\n")
    File.chmod(0o755, File.join(seed, "bin/verify-changed"))
    File.write(File.join(seed, ".gitignore"), ".verify-exit\n")
    git(seed, "add", ".")
    git(seed, "commit", "--quiet", "-m", "Seed")
    git(seed, "push", "--quiet", "origin", "HEAD:refs/heads/master")
  end

  def lane_push(*, dir: work)
    out, status = Bundler.with_unbundled_env { Open3.capture2e("bin/lane-push", *, chdir: dir) }
    [out, status.exitstatus]
  end

  def remote_ref(name)
    out, = Open3.capture2e("git", "rev-parse", "--verify", "--quiet", "refs/heads/#{name}", chdir: remote)
    out.strip.empty? ? nil : out.strip
  end

  def gate_exit(status) = File.write(File.join(work, ".verify-exit"), "#{status}\n")

  it "pushes a new branch to its own ref and leaves master alone under push.default=tracking" do
    set_up
    master_before = remote_ref("master")
    out, status = lane_push
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

  it "refuses a dirty tree, master, and a tool-prefixed branch" do
    set_up
    File.write(File.join(work, "change.txt"), "uncommitted\n")
    expect(lane_push.last).to eq(1)
    git(work, "checkout", "--quiet", "--", "change.txt")

    git(work, "checkout", "--quiet", "-b", "claude/some-task")
    expect(lane_push.last).to eq(1)
    expect(remote_ref("claude/some-task")).to be_nil

    git(work, "checkout", "--quiet", "-B", "master", "origin/master")
    commit_file(work, "on-master.txt", "a lane commit on master\n")
    master_before = remote_ref("master")
    expect(lane_push.last).to eq(1)
    expect(remote_ref("master")).to eq(master_before)
    expect(remote_ref("feature")).to be_nil
  end
end
