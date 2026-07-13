# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/plugin/base"

# ADR-85 WD1 fixture — a synthetic producer-bearing plugin. Its `:probe` producer bumps a class-level
# scan counter and reads nothing (empty dependency descriptor → always fresh after the first write),
# and `#prepare` consults it on every run. So a warm recheck that serves the producer from the disk
# cache never re-runs the block; `.scans` is the scan-count seam the WD1 spec asserts on. Guarded so a
# re-load of this spec file does not redeclare the manifest/producer.
module Rigor
  module Plugin
    unless defined?(Wd1CacheProbe)
      class Wd1CacheProbe < Base
        @scans = 0
        class << self
          attr_accessor :scans
        end

        manifest(id: "wd1-cache-probe", version: "0.1.0")

        producer :probe do |_params|
          Wd1CacheProbe.scans += 1
          "probe-value"
        end

        def prepare(_services)
          producer_value(:probe)
        end
      end
    end
  end
end

# ADR-46 slice 2 — the in-memory incremental orchestrator. The acceptance property (the `--verify-incremental` gate,
# here without disk persistence or CLI wiring): after a real on-disk edit, `#recheck` re-analyzes only the affected
# closure and serves the rest from cache, yet its merged diagnostics are byte-identical — as a sorted set — to a full
# re-analysis of the edited tree.
RSpec.describe Rigor::Analysis::IncrementalSession do
  def configuration(dir)
    Rigor::Configuration.new("paths" => [dir])
  end

  def shared_environment
    @shared_environment ||= Rigor::Environment.for_project
  end

  def full_run(dir)
    config = configuration(dir)
    Rigor::Analysis::Runner.new(
      configuration: config, cache_store: nil, environment: shared_environment
    ).run.diagnostics
  end

  def session_for(config, paths: nil)
    described_class.new(configuration: config, paths: paths, environment: shared_environment)
  end

  def sorted(diagnostics)
    diagnostics.map(&:to_h).sort_by { |hash| [hash["path"], hash["line"], hash["column"], hash["rule"]] }
  end

  def fingerprint(config, dir)
    Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: [dir])
  end

  # A self-contained `def.override-visibility-reduced` (balanced profile → :warning) plus a referenceable class.
  # `reduced:` toggles the diagnostic.
  def write_unit(path, prefix:, reduced: true)
    File.write(path, <<~RUBY)
      class #{prefix}Base
        def tag
          "x"
        end
      end

      class #{prefix}Sub < #{prefix}Base
        #{"private\n" if reduced}
        def tag
          "y"
        end
      end
    RUBY
  end

  it "matches a full re-analysis after a leaf body edit while re-checking one file" do
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.rb")
      b = File.join(dir, "b.rb")
      write_unit(a, prefix: "A")
      write_unit(b, prefix: "B")

      session = session_for(configuration(dir))
      session.baseline

      # Body edit to a.rb only — erase its diagnostic. b.rb is untouched.
      write_unit(a, prefix: "A", reduced: false)

      recheck = session.recheck

      # Only a.rb was re-analyzed; b.rb was served from cache.
      expect(recheck.changed).to eq(Set[a])
      expect(recheck.affected).to eq(Set[a])
      expect(recheck.reused).to include(b)

      # The merged result equals a full re-analysis of the edited tree.
      expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
    end
  end

  it "matches a full re-analysis when nothing changed (all served from cache)" do
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.rb")
      write_unit(a, prefix: "A")

      session = session_for(configuration(dir))
      session.baseline
      recheck = session.recheck

      expect(recheck.changed).to be_empty
      expect(recheck.affected).to be_empty
      expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
    end
  end

  it "stays correct across two successive edits (multi-round state)" do
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.rb")
      b = File.join(dir, "b.rb")
      write_unit(a, prefix: "A")
      write_unit(b, prefix: "B")

      session = session_for(configuration(dir))
      session.baseline

      # Round 1: erase a.rb's diagnostic.
      write_unit(a, prefix: "A", reduced: false)
      r1 = session.recheck
      expect(sorted(r1.diagnostics)).to eq(sorted(full_run(dir)))

      # Round 2: erase b.rb's diagnostic too. The session's cache for a.rb must already reflect round 1, so the merge
      # stays correct.
      write_unit(b, prefix: "B", reduced: false)
      r2 = session.recheck
      expect(r2.changed).to eq(Set[b])
      expect(sorted(r2.diagnostics)).to eq(sorted(full_run(dir)))
    end
  end

  # ADR-46 slice 3 — negative-dependency tracking. A top-level call has no class ancestry to walk, so a miss records no
  # positive edge; without the negative edge a caller's `call.unresolved-toplevel` would be served stale after the
  # method is defined elsewhere.
  describe "negative (appeared-symbol) dependencies" do
    it "re-checks a caller whose missed top-level method is defined by an edit" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        File.write(a, "helper()\n")
        File.write(b, "class Placeholder\nend\n")

        session = session_for(configuration(dir))
        baseline = session.baseline
        # Baseline: a.rb fires call.unresolved-toplevel for the undefined helper.
        expect(baseline.map(&:rule)).to include("call.unresolved-toplevel")

        # Define the top-level helper in b.rb — a.rb's diagnostic must clear.
        File.write(b, "def helper\n  1\nend\n")
        recheck = session.recheck

        # a.rb is pulled into the affected closure by the appeared `helper`, so the merged result matches a full
        # re-analysis (no stale FP).
        expect(recheck.affected).to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        expect(sorted(recheck.diagnostics).map { |h| h["rule"] }).not_to include("call.unresolved-toplevel")
      end
    end

    it "re-checks a subclass when its previously-undefined superclass is added" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        # ASub overrides tag with reduced visibility, but NewBase does not yet exist, so no def.override-* fires at
        # baseline.
        File.write(a, "class ASub < NewBase\n  private\n\n  def tag\n    \"y\"\n  end\nend\n")
        File.write(b, "class Placeholder\nend\n")

        session = session_for(configuration(dir))
        baseline = session.baseline
        expect(baseline.map(&:rule)).not_to include("def.override-visibility-reduced")

        # Define NewBase (with a public tag) in b.rb — ASub now reduces its visibility, so the override diagnostic must
        # appear.
        File.write(b, "class NewBase\n  def tag\n    \"x\"\n  end\nend\n")
        recheck = session.recheck

        expect(recheck.affected).to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        expect(sorted(recheck.diagnostics).map { |h| h["rule"] }).to include("def.override-visibility-reduced")
      end
    end

    it "does not re-check a caller when an unrelated symbol appears" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        File.write(a, "missing_helper()\n")
        File.write(b, "class Thing\n  def existing\n    1\n  end\nend\n")

        session = session_for(configuration(dir))
        session.baseline
        # Add an unrelated top-level method — a.rb missed `missing_helper`, not `other`, so it must stay served from
        # cache.
        File.write(b, "class Thing\n  def existing\n    1\n  end\nend\n\ndef other\n  2\nend\n")
        recheck = session.recheck

        expect(recheck.affected).not_to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end
  end

  # ADR-46 slice 3 (structural tier) — files added / removed between runs are reconciled incrementally (the `paths:` set
  # is no longer in the snapshot fingerprint), leaning on the appeared-symbol/class negative edges for additions and the
  # positive dependents of removed files for removals.
  describe "file addition / removal" do
    it "re-checks a caller when a new file defines its missing top-level method" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, "helper()\n")

        session = session_for(configuration(dir))
        session.baseline

        File.write(File.join(dir, "b.rb"), "def helper\n  1\nend\n")
        recheck = session.recheck

        expect(recheck.affected).to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        expect(sorted(recheck.diagnostics).map { |h| h["rule"] }).not_to include("call.unresolved-toplevel")
      end
    end

    it "re-checks a subclass when a new file defines its missing superclass" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, "class ASub < NewBase\n  private\n\n  def tag\n    \"y\"\n  end\nend\n")

        session = session_for(configuration(dir))
        session.baseline

        File.write(File.join(dir, "b.rb"), "class NewBase\n  def tag\n    \"x\"\n  end\nend\n")
        recheck = session.recheck

        expect(recheck.affected).to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "re-checks dependents and drops the cache entry when a file is removed" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        File.write(a, "helper()\n")
        File.write(b, "def helper\n  1\nend\n")

        session = session_for(configuration(dir))
        session.baseline

        File.delete(b)
        recheck = session.recheck

        # a.rb re-checked (now fires unresolved-toplevel); b.rb gone from the analyzed set and the merged diagnostics.
        expect(recheck.affected).to include(a)
        expect(session.analyzed_files).not_to include(b)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        expect(recheck.diagnostics.map { |d| d.path.to_s }).not_to include(b)
      end
    end

    it "does not re-check unrelated files when a new file is added" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, "x = 1\nputs x\n")

        session = session_for(configuration(dir))
        session.baseline

        added = File.join(dir, "b.rb")
        File.write(added, "class Wholly\n  def z\n    1\n  end\nend\n")
        recheck = session.recheck

        expect(recheck.affected).not_to include(a)
        expect(recheck.affected).to include(added)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "reconciles an added file across processes via the snapshot" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, "helper()\n")
        config = configuration(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))
        fp = fingerprint(config, dir)

        # Process 1 — cold baseline.
        _d1, warm1 = session_for(config, paths: [dir])
                     .run_incremental(snapshot: snapshot, fingerprint: fp)
        expect(warm1).to be(false)

        # A new file appears between processes; the roots-keyed fingerprint is unchanged, so the snapshot still loads.
        File.write(File.join(dir, "b.rb"), "def helper\n  1\nend\n")
        diags2, warm2 = session_for(config, paths: [dir])
                        .run_incremental(snapshot: snapshot, fingerprint: fp)
        expect(warm2).to be(true)
        expect(sorted(diags2)).to eq(sorted(full_run(dir)))
      end
    end
  end

  describe "#run_incremental (cross-process persistence)" do
    it "is cold on first run and warm (snapshot-reusing) afterwards, matching a full run" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        write_unit(a, prefix: "A")
        write_unit(b, prefix: "B")

        config = configuration(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))
        fp = fingerprint(config, dir)

        # Process 1 — cold: no snapshot yet, full analysis, persists.
        _diags, warm1 = session_for(config, paths: [dir])
                        .run_incremental(snapshot: snapshot, fingerprint: fp)
        expect(warm1).to be(false)

        # An edit between "processes" — erase a.rb's diagnostic. Content is not part of the fingerprint, so the snapshot
        # still loads.
        write_unit(a, prefix: "A", reduced: false)

        # Process 2 — warm: a fresh session restores the snapshot and re-analyzes only the changed closure.
        diags2, warm2 = session_for(config, paths: [dir])
                        .run_incremental(snapshot: snapshot, fingerprint: fp)
        expect(warm2).to be(true)
        expect(sorted(diags2)).to eq(sorted(full_run(dir)))
      end
    end

    it "falls back to a cold full run when the fingerprint does not match" do
      Dir.mktmpdir do |dir|
        write_unit(File.join(dir, "a.rb"), prefix: "A")
        config = configuration(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))

        session_for(config, paths: [dir])
          .run_incremental(snapshot: snapshot, fingerprint: "fp-original")
        # A different fingerprint (config / gem / version drift) → cold.
        _diags, warm = session_for(config, paths: [dir])
                       .run_incremental(snapshot: snapshot, fingerprint: "fp-changed")
        expect(warm).to be(false)
      end
    end

    # ADR-87 WD3 — a warm recheck with NO file change leaves the session state byte-equivalent to the
    # snapshot it restored, so `run_incremental` must NOT rewrite it (the 209 ms + 2 MB gitlab null tax). A
    # real edit still persists, and a cold baseline always writes the first snapshot.
    it "skips the snapshot save on a zero-change warm recheck, but writes on cold and on an edit" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        write_unit(a, prefix: "A")
        config = configuration(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))
        fp = fingerprint(config, dir)

        allow(snapshot).to receive(:save).and_call_original

        # Cold baseline: no prior snapshot → MUST save.
        session_for(config, paths: [dir]).run_incremental(snapshot: snapshot, fingerprint: fp)
        expect(snapshot).to have_received(:save).once

        # Warm, zero changes → MUST NOT save (byte-equivalent snapshot already on disk); the call count stays 1.
        _diags, warm = session_for(config, paths: [dir]).run_incremental(snapshot: snapshot, fingerprint: fp)
        expect(warm).to be(true)
        expect(snapshot).to have_received(:save).once

        # A real edit → MUST save again so the new state persists (count advances to 2).
        write_unit(a, prefix: "A", reduced: false)
        session_for(config, paths: [dir]).run_incremental(snapshot: snapshot, fingerprint: fp)
        expect(snapshot).to have_received(:save).twice
      end
    end
  end

  # ADR-85 WD1 — the cross-process win: a warm `--incremental` recheck must serve plugin `#prepare`
  # producers from the disk cache instead of recomputing (the fresh-runner-with-nil-store bug that made a
  # Rails warm incremental ~86% plugin `#prepare`). Two fresh sessions share a cache root + snapshot — the
  # faithful simulation of two `rigor check --incremental` processes, the established pundit /
  # cache-producer cross-process pattern: a fresh `Store` has an empty in-memory memo, so a hit is a real
  # disk read.
  describe "#run_incremental plugin-producer cache reuse (WD1)" do
    let(:probe_producer_id) { "plugin.wd1-cache-probe.probe" }

    def probe_requirer
      lambda do |_name|
        Rigor::Plugin.register(Rigor::Plugin::Wd1CacheProbe)
        true
      end
    end

    def probe_config(dir)
      Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => [dir], "plugins" => ["wd1-cache-probe"])
      )
    end

    def run_probe_incremental(config, dir, snapshot, fingerprint_hex, cache_store)
      # Each "process" unregisters first so the loader's newly-registered diff sees a fresh registration.
      Rigor::Plugin.unregister!
      described_class.new(
        configuration: config, paths: [dir], cache_store: cache_store, plugin_requirer: probe_requirer
      ).run_incremental(snapshot: snapshot, fingerprint: fingerprint_hex)
    end

    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    it "serves the producer from cache on the second process's recheck (no recompute)" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "x = 1\nputs x\n")
        config = probe_config(dir)
        cache_root = File.join(dir, ".rigor", "cache")
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: cache_root)
        fp = fingerprint(config, dir)
        Rigor::Plugin::Wd1CacheProbe.scans = 0

        # Process 1 — cold baseline: the producer misses and computes once, warming the disk cache.
        store1 = Rigor::Cache::Store.new(root: cache_root)
        _d1, warm1 = run_probe_incremental(config, dir, snapshot, fp, store1)
        expect(warm1).to be(false)
        expect(Rigor::Plugin::Wd1CacheProbe.scans).to eq(1)
        expect(store1.stats[:by_producer][probe_producer_id]).to include(misses: 1, writes: 1)

        # Process 2 — warm recheck (fresh session, fresh Store, same disk root): `#prepare` consults the
        # producer, which now serves from disk. The block never re-runs (scans stays 1) and the store
        # records a hit with no miss.
        store2 = Rigor::Cache::Store.new(root: cache_root)
        _d2, warm2 = run_probe_incremental(config, dir, snapshot, fp, store2)
        expect(warm2).to be(true)
        expect(Rigor::Plugin::Wd1CacheProbe.scans).to eq(1)
        expect(store2.stats[:by_producer][probe_producer_id]).to include(hits: 1, misses: 0)
      end
    end

    it "recomputes the producer every process when no store is threaded (the pre-WD1 behaviour)" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "x = 1\nputs x\n")
        config = probe_config(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".rigor", "cache"))
        fp = fingerprint(config, dir)
        Rigor::Plugin::Wd1CacheProbe.scans = 0

        run_probe_incremental(config, dir, snapshot, fp, nil)
        run_probe_incremental(config, dir, snapshot, fp, nil)

        # With no store, each process re-runs `#prepare`'s producer block — the regression WD1 fixes.
        expect(Rigor::Plugin::Wd1CacheProbe.scans).to eq(2)
      end
    end
  end
end
