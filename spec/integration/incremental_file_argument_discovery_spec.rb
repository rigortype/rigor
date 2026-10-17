# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/incremental_session"
require "rigor/analysis/runner"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

# Issue #1583 — `rigor check --incremental lib/b.rb` under `paths: [lib]`. A run over path arguments discovers the
# configured paths as well (#684), so `lib/b.rb`'s `LIMIT.upcase` resolves `LIMIT` from `lib/a.rb`. The session's
# baseline widened that way, but its rechecks and `--verify-incremental`'s partitions (`analyze_only:` runs) did not,
# and an edit to `lib/a.rb` — discovered, never analysed — was seen by no digest the session kept (#1560).
#
# The oracle in every example is a full `--no-cache` run over the same arguments.
RSpec.describe "--incremental over path arguments under a configured path (#1583)" do
  around do |example|
    Dir.mktmpdir("rigor-incremental-file-arg-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:configured) { %w[lib] }
  let(:paths) { %w[lib/b.rb] }

  before do
    FileUtils.mkdir_p("lib")
    File.write("lib/a.rb", "LIMIT = 3\n")
    File.write("lib/b.rb", "def m\n  LIMIT.upcase\nend\n")
  end

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => configured))
  end

  def rows(diagnostics)
    diagnostics.select { |d| d.rule == "call.undefined-method" }.map { |d| [d.path, d.line] }.sort
  end

  def full_rows
    rows(guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), paths).diagnostics)
  end

  def session
    Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths)
  end

  # One `rigor check --incremental` process: a fresh session over the on-disk snapshot.
  def incremental_rows
    root = File.join(Dir.pwd, ".rigor", "cache")
    snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
    fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
    diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
    [rows(diagnostics), warm]
  end

  it "keeps the sibling's constant in view when the argument is re-analysed" do
    expect(full_rows).to eq([["lib/b.rb", 2]])
    live = session
    guarded_baseline(live)
    File.write("lib/b.rb", "def m\n  LIMIT.upcase\nend\n# edited\n")
    expect(rows(guarded_recheck(live).diagnostics)).to eq([["lib/b.rb", 2]])
  end

  it "answers --verify-incremental's partition the way the full run does" do
    live = session
    expect(rows(guarded_baseline(live))).to eq(full_rows)
    expect(rows(guarded_reanalyze_subset(live, paths))).to eq(full_rows)
  end

  it "re-checks the argument when the discovered sibling is edited" do
    expect(incremental_rows).to eq([[["lib/b.rb", 2]], false])
    expect(incremental_rows).to eq([[["lib/b.rb", 2]], true])
    File.write("lib/a.rb", "LIMIT = \"x\"\n")
    expect(full_rows).to eq([])
    expect(incremental_rows.first).to eq([])
    # The re-baseline persisted the new digest, so the next run is warm again.
    expect(incremental_rows).to eq([[], true])
  end

  it "re-checks the argument when the discovered sibling is removed" do
    incremental_rows
    File.delete("lib/a.rb")
    expect(full_rows).to eq([])
    expect(incremental_rows.first).to eq([])
  end

  it "re-checks the argument when a discovered file appears" do
    File.delete("lib/a.rb")
    expect(incremental_rows.first).to eq([])
    File.write("lib/a.rb", "LIMIT = 3\n")
    expect(full_rows).to eq([["lib/b.rb", 2]])
    expect(incremental_rows.first).to eq([["lib/b.rb", 2]])
  end

  # Issue #1560's shape: a directory argument under `paths: [lib, ext]`, and an edit under `ext`.
  context "with a second configured path the argument directory depends on" do
    let(:configured) { %w[lib ext] }
    let(:paths) { %w[lib] }

    before do
      FileUtils.mkdir_p("ext")
      File.write("ext/e.rb", "EXT = 3\n")
      File.write("lib/l.rb", "def l\n  EXT.upcase\nend\n")
    end

    it "re-checks the argument directory when a file under the other path is edited" do
      expect(incremental_rows).to eq([[["lib/b.rb", 2], ["lib/l.rb", 2]], false])
      File.write("ext/e.rb", "EXT = \"x\"\n")
      expect(full_rows).to eq([["lib/b.rb", 2]])
      expect(incremental_rows.first).to eq([["lib/b.rb", 2]])
    end
  end

  # A run over the configured paths discovers nothing it does not analyse, so the session keeps no discovery
  # digests and a run that changed nothing stays warm.
  context "when run over the configured paths" do
    let(:paths) { configured }

    it "records no discovery-only file" do
      expect(incremental_rows).to eq([[["lib/b.rb", 2]], false])
      expect(incremental_rows).to eq([[["lib/b.rb", 2]], true])
      expect(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
        .discovery_only_file_set(paths)).to eq([])
    end
  end
end
