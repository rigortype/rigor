# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# Issue #1967 — `--verify-incremental` re-analyses half of an unchanged tree, so it cannot see a missing invalidation
# edge: with nothing edited, every served row is still right. `--verify-incremental-edits N` replays an edit on N
# sampled files (each emptied through an editor buffer, never on disk) and compares the warm recheck with a full run
# of the edited tree.
#
# The fixture is #2158's: `use.rb` writes `$stdout = 1`, which `other.rb`'s `def write` silences. Emptying
# `other.rb` makes a full run report the write, and only the `global_census:` edge puts `use.rb` into the recheck.
RSpec.describe Rigor::CLI do
  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.start(argv, out: out, err: err)

    [status, out.string, err.string]
  end

  around do |example|
    Dir.mktmpdir("rigor-verify-edits-") do |dir|
      @dir = File.realpath(dir)
      File.write(File.join(@dir, ".rigor.yml"), "paths:\n  - lib\n")
      FileUtils.mkdir_p(File.join(@dir, "lib"))
      File.write(File.join(@dir, "lib", "use.rb"), "$stdout = 1\n")
      File.write(File.join(@dir, "lib", "other.rb"), "class Other\n  def write(*) = nil\nend\n")
      Dir.chdir(@dir) { example.run }
    end
  end

  def verify(*extra)
    run_cli("check", "--verify-incremental", "--no-stats", "--config", File.join(@dir, ".rigor.yml"), *extra)
  end

  it "replays an edit of each sampled file and reports OK when every recheck matches a full run" do
    status, out, err = verify("--verify-incremental-edits", "2")

    expect(err).to eq("")
    expect(out).to include("--verify-incremental OK")
    expect(out).to include("2 edits replayed (each file emptied), every recheck matches full")
    expect(status).to eq(0)
  end

  it "fails and names the edited file when a recheck after the edit differs from a full run" do
    original = Rigor::Analysis::IncrementalSession.instance_method(:replay_edit)
    allow_any_instance_of(Rigor::Analysis::IncrementalSession).to receive(:replay_edit) do |session, buffer|
      result = original.bind_call(session, buffer)
      result&.with(diagnostics: result.diagnostics.reject { |row| row.path.end_with?("use.rb") })
    end

    status, _out, err = verify("--verify-incremental-edits", "2")

    expect(err).to match(%r{--verify-incremental FAILED — the recheck after emptying \S*lib/other\.rb differs from a full run\.})
    expect(err).to include("incremental-only: 0, full-only: 1")
    expect(status).to eq(1)
  end

  # A guard: without the option the gate replays nothing and prints the line it always has.
  it "replays no edit by default" do
    status, out, = verify

    expect(out).to include("--verify-incremental OK")
    expect(out).not_to include("edits replayed")
    expect(status).to eq(0)
  end

  it "rejects a negative count" do
    status, _out, err = verify("--verify-incremental-edits", "-1")

    expect(err).to include("--verify-incremental-edits")
    expect(status).not_to eq(0)
  end
end
