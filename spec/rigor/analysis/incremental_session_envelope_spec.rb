# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "rigor/cli/check_command"

# Issue #1898 — `effect.envelope-exceeded` is judged once per run over the propagated effect graph, outside
# per-file analysis. A narrowed recheck closed that graph over only the files it re-analysed, so a recheck
# that left the declaring file out of its closure (no change at all, or an unrelated edit) lost the row the
# baseline reported. The session now hands the runner the collections it serves for the unanalysed files.
RSpec.describe "effect.envelope-exceeded across incremental rechecks" do
  def rule = "effect.envelope-exceeded"
  def pure_rbs = "class Foo\n  %a{pure} def bar: () -> nil\nend\n"
  def plain_rbs = "class Foo\n  def bar: () -> nil\nend\n"
  def impure_ruby = "class Foo\n  def bar\n    puts \"hi\"\n  end\nend\n"
  def pure_ruby = "class Foo\n  def bar\n    nil\n  end\nend\n"

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = File.realpath(dir)
      FileUtils.mkdir_p([lib_path, sig_path])
      write("sig/foo.rbs", pure_rbs)
      write("lib/a.rb", impure_ruby)
      write("lib/b.rb", "class Other\n  def x = 1\nend\n")
      example.run
    end
  end

  attr_reader :dir

  def lib_path = File.join(dir, "lib")
  def sig_path = File.join(dir, "sig")

  def write(relative, content)
    File.write(File.join(dir, relative), content)
  end

  def session_for(workers: 0)
    configuration = Rigor::Configuration.new(
      "paths" => [lib_path], "signature_paths" => [sig_path], "effects" => {}
    )
    Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: [lib_path], workers: workers)
  end

  def envelope_rows(diagnostics)
    diagnostics.select { |diagnostic| diagnostic.rule == rule }.map(&:to_h)
  end

  [0, 2].each do |workers|
    it "keeps the row byte-identical on a no-change recheck (workers: #{workers})" do
      session = session_for(workers: workers)
      baseline = envelope_rows(guarded_baseline(session))
      recheck = guarded_recheck(session)

      expect(baseline.size).to eq(1)
      expect(recheck.affected).to be_empty
      expect(envelope_rows(recheck.diagnostics)).to eq(baseline)
    end
  end

  it "keeps the row after an edit to a file outside the declaring file's closure" do
    session = session_for
    baseline = envelope_rows(guarded_baseline(session))
    write("lib/b.rb", "class Other\n  def x = 2\nend\n")
    recheck = guarded_recheck(session)

    expect(recheck.affected).not_to include(File.join(lib_path, "a.rb"))
    expect(envelope_rows(recheck.diagnostics)).to eq(baseline)
  end

  # A guard: the declaring file is in the closure here, so this passed before #1898's fix too.
  it "drops the row when the body stops exceeding the envelope, then restores it" do
    session = session_for
    baseline = envelope_rows(guarded_baseline(session))
    write("lib/a.rb", pure_ruby)
    expect(envelope_rows(guarded_recheck(session).diagnostics)).to be_empty

    write("lib/a.rb", impure_ruby)
    expect(envelope_rows(guarded_recheck(session).diagnostics)).to eq(baseline)
  end

  # The session still holds the deleted file's collection when the recheck starts; serving it would judge a
  # method that no longer exists.
  it "drops the row when the declaring file is deleted" do
    session = session_for
    guarded_baseline(session)
    FileUtils.rm(File.join(lib_path, "a.rb"))

    expect(envelope_rows(guarded_recheck(session).diagnostics)).to be_empty
  end

  it "drops the row when the RBS loses %a{pure}, then restores it with no Ruby edit" do
    session = session_for
    baseline = envelope_rows(guarded_baseline(session))
    write("sig/foo.rbs", plain_rbs)
    expect(envelope_rows(guarded_recheck(session).diagnostics)).to be_empty

    write("sig/foo.rbs", pure_rbs)
    expect(envelope_rows(guarded_recheck(session).diagnostics)).to eq(baseline)
  end

  # `--verify-incremental` re-analyses every other file; with the declaring file outside that subset its
  # row came from nowhere, and the gate compared an incremental side missing it against a full side with it.
  it "keeps the row in a verification subset that leaves the declaring file out" do
    session = session_for
    baseline = envelope_rows(guarded_baseline(session))

    subset = guarded_reanalyze_subset(session, [File.join(lib_path, "b.rb")])

    expect(envelope_rows(subset)).to eq(baseline)
  end

  # `effect.liskov-widened` is judged in the same pass over the same table, against the parent's envelope.
  it "keeps an effect.liskov-widened row whose overriding file is served from the session" do
    write("lib/base.rb", "class Base\n  def run\n    nil\n  end\nend\n")
    write("lib/kid.rb", "class Kid < Base\n  def run\n    puts 1\n  end\nend\n")
    write("sig/base.rbs", "class Base\n  %a{pure} def run: () -> nil\nend\n")
    session = session_for
    widened = guarded_baseline(session).select { |row| row.rule == "effect.liskov-widened" }.map(&:to_h)
    write("lib/b.rb", "class Other\n  def x = 2\nend\n")
    recheck = guarded_recheck(session)

    expect(widened.map { |row| row.fetch("path") }).to eq([File.join(lib_path, "kid.rb")])
    expect(recheck.reused).to include(File.join(lib_path, "kid.rb"))
    rechecked = recheck.diagnostics.select { |row| row.rule == "effect.liskov-widened" }.map(&:to_h)
    expect(rechecked).to eq(widened)
  end

  describe "through rigor check --incremental" do
    around do |example|
      Dir.chdir(dir) do
        File.write(".rigor.yml", "paths:\n  - lib\nsignature_paths:\n  - sig\neffects: {}\n")
        example.run
      end
    end

    def check(workers)
      out = StringIO.new
      err = StringIO.new
      argv = ["--no-ci-detect", "--no-stats", "--no-baseline", "--format", "json", "--incremental",
              "--workers=#{workers}", "lib"]
      Rigor::CLI::CheckCommand.new(argv: argv, out: out, err: err).run
      rows = JSON.parse(out.string).fetch("diagnostics").select { |row| row["rule"] == rule }
      [rows, err.string]
    end

    [0, 2].each do |workers|
      it "reports the cold run's row on the warm runs that follow (workers: #{workers})" do
        cold, cold_err = check(workers)
        null_warm, null_err = check(workers)
        write("lib/b.rb", "class Other\n  def x = 2\nend\n")
        unrelated_warm, unrelated_err = check(workers)

        expect(cold_err).to include("--incremental cold")
        expect([null_err, unrelated_err]).to all(include("--incremental warm"))
        expect(cold.size).to eq(1)
        expect(null_warm).to eq(cold)
        expect(unrelated_warm).to eq(cold)
      end
    end
  end
end
