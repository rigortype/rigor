# frozen_string_literal: true

# Gates `bin/rigor-claim`, the cross-session ticket mutex. Every example runs in a
# throwaway clone, never this one: a claim is live state shared by every worktree
# of the repository it is taken in, so a spec that used the real `.git` would
# fight the sessions the script exists to coordinate.
#
# The behaviours pinned here are the ones that failed in review. `set -euo
# pipefail` makes a shell script fail *silently*: an `awk` printf without a
# trailing newline, and a `shift 2` past the end of the argument list, each made
# every subcommand exit 1 printing nothing at all. Neither is visible to
# shellcheck, so an exit status and a stream are asserted for each path.
require "fileutils"
require "open3"
require "tmpdir"
require "spec_helper"

RSpec.describe "bin/rigor-claim" do
  let(:script) { File.expand_path("../../bin/rigor-claim", __dir__) }

  # One throwaway clone per example, created on first use and removed afterwards.
  # A `let` rather than an `around` ivar: six RSpec/InstanceVariable offences is
  # what the ivar form costs, and the lazy `let` also skips the clone for the
  # examples that never reach a repository.
  let(:tmpdir) { Dir.mktmpdir("rigor-claim-spec") }
  let(:repo) do
    path = File.join(tmpdir, "clone")
    Dir.mkdir(path)
    _, err, status = Open3.capture3("git", "init", "--quiet", path)
    raise "git init failed: #{err}" unless status.success?

    path
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  # Runs the script as `session` and returns [stdout, stderr, exit status].
  #
  # The harness variables are cleared on every call (Open3 unsets a nil value):
  # this spec runs inside a Claude Code session, which exports exactly the ids the
  # script falls back to, so leaving them in place would hide the missing-session
  # path and stamp a real host id into a record an example wants empty.
  def claim(*, session: "sess-A", cwd: repo, pid: nil, host: nil)
    env = {
      "CLAUDE_CODE_SESSION_ID" => nil, "CLAUDE_CODE_HOST_SESSION_ID" => nil, "CLAUDE_PID" => nil,
      "RIGOR_CLAIM_SESSION" => session, "RIGOR_CLAIM_HOST" => host, "RIGOR_CLAIM_PID" => pid
    }
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(env, script, *, chdir: cwd)
    end
    [out, err, status.exitstatus]
  end

  def blob_of(number, **)
    out, = claim("list", **)
    out[/^\##{number}\t.*?\tblob=(\h{40})/, 1]
  end

  describe "the mutex" do
    it "takes a free number and refuses it to another session with exit 10" do
      out, _, status = claim("take", "3253", "--note", "review round")
      expect(status).to eq(0)
      expect(out).to eq("#3253\ttaken\n")

      out, _, status = claim("check", "3253", session: "sess-B")
      expect(status).to eq(10)
      expect(out).to match(/^#3253\tHELD\tsession=sess-A\b/)
    end

    it "reports a number this session already holds as mine, not as a conflict" do
      claim("take", "3253")
      out, _, status = claim("check", "3253")
      expect(status).to eq(0)
      expect(out).to match(/^#3253\tmine\b/)

      # Re-taking is idempotent: a coordinator that lost track must not be refused
      # its own claim, since that would read as a sibling session owning the work.
      out, _, status = claim("take", "3253")
      expect(status).to eq(0)
      expect(out).to match(/^#3253\tmine\b/)
    end

    it "exits 0 only when every number of a check is free or mine" do
      claim("take", "10", session: "sess-B")
      out, _, status = claim("check", "11", "10", "12")
      expect(status).to eq(10)
      expect(out.lines.grep(/\tfree$/).length).to eq(2)
    end
  end

  describe "a refused batch" do
    it "releases what the run took and keeps what the session already held" do
      claim("take", "100")
      claim("take", "200", session: "sess-B")

      # Sorted, the run walks 100 (already mine), 150 (taken here), 200 (refused).
      out, err, status = claim("take", "200", "100", "150")
      expect(status).to eq(10)
      expect(err).to match(/^#200\tHELD\tsession=sess-B\b/)
      expect(out).to include("#150\treleased (batch refused)")

      # 150 was this run's, so it goes back; 100 was already held, so it stays.
      expect(claim("check", "150").first).to eq("#150\tfree\n")
      expect(claim("check", "100").first).to match(/\tmine\b/)
    end

    it "validates every number before the first claim, so a bad tail claims nothing" do
      out, err, status = claim("take", "4001", "4002", "#4003")
      expect(status).to eq(2)
      expect(err).to include("not a ticket number: #4003")
      expect(out).to be_empty
      expect(claim("check", "4001", "4002").first.lines).to all(match(/\tfree$/))
    end

    it "sorts a batch so two sessions claiming the same pair cannot refuse each other" do
      # Taken in opposite orders, both runs walk 7 before 9. Without the sort,
      # each would win one number, refuse the other, and both end with nothing.
      expect(claim("take", "9", "7").first).to eq("#7\ttaken\n#9\ttaken\n")
      _, err, status = claim("take", "7", "9", session: "sess-B")
      expect(status).to eq(10)
      expect(err).to match(/^#7\tHELD/)
    end
  end

  describe "release" do
    it "refuses to drop another session's claim, and offers the steal instead" do
      claim("take", "55")
      _, err, status = claim("drop", "55", session: "sess-B")
      expect(status).to eq(10)
      expect(err).to match(/held by sess-A.*steal/)
      expect(claim("check", "55").first).to match(/\tmine\b/)
    end

    it "drops only this session's claims with --mine" do
      claim("take", "61", "62")
      claim("take", "63", session: "sess-B")
      out, _, status = claim("drop", "--mine")
      expect(status).to eq(0)
      expect(out.lines.map(&:strip)).to eq(["#61\tdropped", "#62\tdropped"])
      expect(claim("check", "63", session: "sess-B").first).to match(/\tmine\b/)
    end

    it "says so rather than failing when a session holds nothing" do
      out, _, status = claim("drop", "--mine")
      expect(status).to eq(0)
      expect(out).to eq("no claims held by this session\n")
    end
  end

  describe "steal" do
    it "is a compare-and-swap, so a second stealer of the same value loses" do
      claim("take", "70")
      blob = blob_of(70)
      expect(blob).to match(/\A\h{40}\z/)

      out, _, status = claim("steal", "70", "--from", blob, session: "sess-B")
      expect(status).to eq(0)
      expect(out).to eq("#70\tstolen from #{blob}\n")

      _, err, status = claim("steal", "70", "--from", blob, session: "sess-C")
      expect(status).to eq(10)
      expect(err).to match(/no longer holds #{blob}/)
      expect(claim("check", "70", session: "sess-B").first).to match(/\tmine\b/)
    end

    it "requires a full non-zero sha, so no rev expression resolves the race back" do
      claim("take", "71")
      ["refs/rigor/claim/71", blob_of(71)[0, 8], "0" * 40].each do |bad|
        _, err, status = claim("steal", "71", "--from", bad, session: "sess-B")
        expect(status).to eq(2), "#{bad} was accepted"
        expect(err).to match(/40-hex|forty zeros/)
      end
      expect(claim("check", "71").first).to match(/\tmine\b/)
    end
  end

  describe "the holder's record" do
    it "keeps its fields apart when one of them is empty" do
      # Tab is IFS whitespace, so reading tab-separated fields collapsed an unset
      # `host` and shifted `since` into its place. RIGOR_CLAIM_HOST is "" here.
      claim("take", "80", "--note", "my note")
      out, = claim("check", "80", session: "sess-B")
      expect(out).to match(/\tsince=\d{4}-\d\d-\d\dT/)
      expect(out).to match(/\tnote=my note$/)
      expect(claim("list").first).to match(/\thost=\tpid=/)
    end

    it "strips newlines from a note, which could otherwise forge the holder" do
      claim("take", "81", "--note", "benign\nsession=attacker")
      expect(claim("check", "81").first).to match(/\tmine\b/)
      expect(claim("list").first).to match(/\tnote=benignsession=attacker$/)
      expect(claim("drop", "81").last).to eq(0)
    end

    it "reports whether the holder's process is still alive, as steal evidence" do
      claim("take", "82", pid: Process.pid.to_s)
      expect(claim("list").first).to match(/\tpid=#{Process.pid}\(alive\)/)

      # A pid that cannot be running: claimed by a session whose process is gone.
      claim("take", "83", pid: "2147483646", session: "sess-B")
      out, = claim("check", "83")
      expect(out).to match(/\tpid=2147483646\(gone\)/)
    end
  end

  describe "arguments and environment" do
    it "prints usage and exits 2 when an option's value is missing" do
      # `shift 2` past the end fails under `set -e`: this exited 1 in silence.
      [%w[take 5 --note], %w[steal 5 --from], %w[check --pr]].each do |args|
        out, err, status = claim(*args)
        expect(status).to eq(2), "#{args.inspect} exited #{status}"
        expect(err).to match(/needs a (value|number)/)
        expect(out).to be_empty
      end
    end

    it "rejects a leading zero, which would key 007 apart from 7" do
      claim("take", "7")
      %w[007 0007 0].each do |bad|
        _, err, status = claim("check", bad)
        expect(status).to eq(2), "#{bad} was accepted"
        expect(err).to include("not a ticket number")
      end
    end

    it "refuses a subcommand's wrong arity rather than guessing" do
      expect(claim("list", "5").last).to eq(2)
      expect(claim("drop", "--mine", "5").last).to eq(2)
      expect(claim("steal", "5", "6", "--from", "a" * 40).last).to eq(2)
      expect(claim("check").last).to eq(2)
      expect(claim("nonsense").last).to eq(2)
      expect(claim.last).to eq(2)
    end

    it "requires a session id for every write, and allows a read without one" do
      _, err, status = claim("take", "5", session: nil)
      expect(status).to eq(2)
      expect(err).to include("no session id")
      expect(claim("check", "5", session: nil).last).to eq(0)
    end

    it "refuses to answer outside a git repository instead of reporting free" do
      Dir.mktmpdir("rigor-claim-outside") do |outside|
        # A read that answered `free` here would licence a duplicate review round.
        _, err, status = claim("check", "5", cwd: outside)
        expect(status).to eq(2)
        expect(err).to include("not a git repository")
        expect(claim("list", cwd: outside).last).to eq(2)
        expect(claim("drop", "--mine", cwd: outside).last).to eq(2)
      end
    end
  end

  describe "a claim git cannot take" do
    it "reports the cause and exits 2 rather than HELD by an empty session" do
      # A stale lockfile fails the CAS while leaving the ref absent. Reported as
      # HELD, that reads as a sibling session owning the ticket, which is wrong
      # in the one direction that costs the factory a stall.
      Dir.mkdir(File.join(repo, ".git", "refs", "rigor"))
      Dir.mkdir(File.join(repo, ".git", "refs", "rigor", "claim"))
      File.write(File.join(repo, ".git", "refs", "rigor", "claim", "90.lock"), "")

      _, err, status = claim("take", "90")
      expect(status).to eq(2)
      expect(err).to include("cannot claim #90 and nothing holds it")
      expect(claim("check", "90").first).to eq("#90\tfree\n")
    end
  end
end
