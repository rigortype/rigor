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
      Dir.chdir(File.realpath(dir)) do
        File.write(".rigor.yml", "paths:\n  - lib\n")
        FileUtils.mkdir_p("lib")
        File.write("lib/use.rb", "$stdout = 1\n")
        File.write("lib/other.rb", "class Other\n  def write(*) = nil\nend\n")
        example.run
      end
    end
  end

  def verify(*extra)
    run_cli("check", "--verify-incremental", "--no-stats", "--config", File.join(Dir.pwd, ".rigor.yml"), *extra)
  end

  # Wraps every session's {Rigor::Analysis::IncrementalSession#replay_edit} so its recheck's rows pass through
  # `transform` first.
  def wrap_replay_edit(&transform)
    allow(Rigor::Analysis::IncrementalSession).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap do |session|
        allow(session).to receive(:replay_edit).and_wrap_original do |method, *method_args|
          result = method.call(*method_args)
          result&.with(diagnostics: transform.call(result.diagnostics))
        end
      end
    end
  end

  it "replays an edit of each sampled file and reports OK when every recheck matches a full run" do
    status, out, err = verify("--verify-incremental-edits", "2")

    expect(err).to eq("")
    expect(out).to include("--verify-incremental OK")
    expect(out).to include("2 edits replayed (each file emptied), every recheck matches full")
    expect(status).to eq(0)
  end

  it "fails and names the edited file when a recheck after the edit differs from a full run" do
    wrap_replay_edit { |rows| rows.reject { |row| row.path.end_with?("use.rb") } }

    status, _out, err = verify("--verify-incremental-edits", "2")

    expect(err).to match(%r{FAILED — the recheck after emptying \S*lib/other\.rb differs from a full run\.})
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
