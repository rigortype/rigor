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

  # ADR-87 WD1 (PR item 1) — change detection stats rather than SHA-256s unchanged files.
  describe "stat-tier change detection" do
    it "detects no change for an unchanged recheck without hashing any content bytes" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        write_unit(a, prefix: "A")
        write_unit(b, prefix: "B")
        session = session_for(configuration(dir))
        session.baseline

        # `Digest::SHA256.file` is the sole content-hashing call; the stat tier must not reach it for an
        # unchanged file (the recon anomaly: the old path SHA-256'd every file every recheck).
        allow(Digest::SHA256).to receive(:file).and_call_original
        changed = session.send(:changed_paths, session.analyzed_files)

        expect(changed).to be_empty
        expect(Digest::SHA256).not_to have_received(:file)
      end
    end

    it "detects a touched-but-identical file as fresh (moved stat tuple, unchanged content)" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        write_unit(a, prefix: "A")
        session = session_for(configuration(dir))
        session.baseline

        # Move mtime/ctime without changing content (a `git checkout` / `touch`); the digest is the authority.
        future = Time.now + 5
        File.utime(future, future, a)

        expect(session.send(:changed_paths, [a])).to be_empty
      end
    end

    it "detects an edited file" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        write_unit(a, prefix: "A")
        session = session_for(configuration(dir))
        session.baseline

        write_unit(a, prefix: "A", reduced: false)

        expect(session.send(:changed_paths, [a])).to eq([a])
      end
    end
  end

  # ADR-46 (PR item 2) — the `--incremental` closure re-analysis is wired to the fork pool.
  describe "fork-pool wiring" do
    def write_greeter(dir, body:)
      base = File.join(dir, "greeter_base.rb")
      File.write(base, "class GreeterBase\n  def greet\n    #{body}\n  end\nend\n")
      base
    end

    it "matches a full re-analysis with workers > 0 across successive edits" do
      skip "fork is unavailable on this platform" unless Process.respond_to?(:fork)
      Dir.mktmpdir do |dir|
        write_greeter(dir, body: '"hi"')
        # A subclass whose implicit-self call resolves `greet` cross-file (records an edge to greeter_base.rb)
        # plus filler files so the pool distributes real slices.
        File.write(File.join(dir, "greeter_sub.rb"), <<~RUBY)
          class GreeterSub < GreeterBase
            def announce
              greet
            end
          end
        RUBY
        3.times { |i| write_unit(File.join(dir, "u#{i}.rb"), prefix: "U#{i}") }

        session = described_class.new(configuration: configuration(dir), environment: shared_environment, workers: 3)
        session.baseline

        write_greeter(dir, body: '"edited"')
        recheck = session.recheck
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))

        # A second edit exercises the graph the FIRST pooled recheck rebuilt from the marshalled records.
        write_greeter(dir, body: '"again"')
        recheck2 = session.recheck
        expect(sorted(recheck2.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end
  end

  # ADR-46 slice 4 singleton extension (PR item 3) — a class/singleton-method body edit gets symbol
  # granularity: its closure scopes to the method's call sites, not the file's coarse dependents.
  describe "singleton-method symbol granularity" do
    def write_util(dir, unused_body:)
      util = File.join(dir, "util.rb")
      File.write(util, <<~RUBY)
        class Util
          def self.used
            "u"
          end

          def self.unused
            #{unused_body}
          end
        end
      RUBY
      util
    end

    it "scopes a class-method body edit to that method's callers (not the file's dependents)" do
      Dir.mktmpdir do |dir|
        util = write_util(dir, unused_body: '"n"')
        ca = File.join(dir, "caller_a.rb")
        cb = File.join(dir, "caller_b.rb")
        File.write(ca, "class CallerA\n  def go\n    Util.used\n  end\nend\n")
        File.write(cb, "class CallerB\n  def go\n    Util.used\n  end\nend\n")

        session = session_for(configuration(dir))
        session.baseline

        # Edit the UNUSED class method's body — nobody calls it, so no caller is affected.
        write_util(dir, unused_body: '"CHANGED"')
        recheck = session.recheck

        expect(recheck.changed).to eq(Set[util])
        expect(recheck.affected).to eq(Set[util])
        expect(recheck.reused).to include(ca, cb)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "re-checks the callers of an edited class method" do
      Dir.mktmpdir do |dir|
        util = File.join(dir, "util.rb")
        File.write(util, "class Util\n  def self.used\n    \"u\"\n  end\nend\n")
        ca = File.join(dir, "caller_a.rb")
        File.write(ca, "class CallerA\n  def go\n    Util.used\n  end\nend\n")

        session = session_for(configuration(dir))
        session.baseline

        # Edit the CALLED class method's body — its caller must be re-analysed.
        File.write(util, "class Util\n  def self.used\n    \"CHANGED\"\n  end\nend\n")
        recheck = session.recheck

        expect(recheck.affected).to include(util, ca)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end
  end

  # B1 — the bundle-equality propagation gate: a changed file whose CODE (comments stripped) is unchanged is
  # declaration-stable, so its ancestry / file-level dependents are skipped. Every case also asserts the
  # merged diagnostics equal a full re-analysis (the `--verify-incremental` soundness property).
  describe "bundle-equality propagation gate" do
    # A base class (with a leading comment) and a subclass that reads its ancestry (an ancestry edge to the
    # base), so an edit to the base normally re-checks the subclass.
    def write_pair(dir, base_comment:)
      base = File.join(dir, "base.rb")
      File.write(base, <<~RUBY)
        # #{base_comment}
        class Base
          def greet
            "hi"
          end
        end
      RUBY
      sub = File.join(dir, "sub.rb")
      File.write(sub, "class Sub < Base\n  def announce\n    greet\n  end\nend\n") unless File.exist?(sub)
      [base, sub]
    end

    it "collapses an in-place comment edit to the edited file, skipping its dependents" do
      Dir.mktmpdir do |dir|
        base, sub = write_pair(dir, base_comment: "the original comment")
        session = session_for(configuration(dir))
        session.baseline

        # Reword the comment — same line count, so the code (and every def's start line) is byte-identical.
        write_pair(dir, base_comment: "a completely different but single-line comment")
        recheck = session.recheck

        expect(recheck.changed).to eq(Set[base])
        expect(recheck.affected).to eq(Set[base]) # sub is skipped despite its ancestry edge to base.rb
        expect(recheck.reused).to include(sub)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "still re-checks dependents on a body edit (the gate must not fire on a code change)" do
      Dir.mktmpdir do |dir|
        base, sub = write_pair(dir, base_comment: "c")
        session = session_for(configuration(dir))
        session.baseline

        # A body edit changes the code fingerprint — the gate must NOT skip the dependent.
        File.write(base, "# c\nclass Base\n  def greet\n    \"HELLO\"\n  end\nend\n")
        recheck = session.recheck

        expect(recheck.affected).to include(base, sub)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "takes the same skip decision on a pooled (workers > 0) recheck as on a sequential one" do
      skip "fork is unavailable on this platform" unless Process.respond_to?(:fork)
      Dir.mktmpdir do |dir|
        base, sub = write_pair(dir, base_comment: "the original comment")
        session = described_class.new(configuration: configuration(dir), environment: shared_environment,
                                      workers: 2)
        session.baseline

        # The gate decision (`affected_closure` → `analyze_set`) happens session-side BEFORE worker
        # dispatch, so a pooled recheck must skip exactly the same dependents a sequential one does.
        write_pair(dir, base_comment: "a different comment, same line count")
        recheck = session.recheck

        expect(recheck.affected).to eq(Set[base])
        expect(recheck.reused).to include(sub)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    # Fabricated-edit soundness battery — one per surface the audit flagged as a suspect (constant, class
    # ivar, class cvar, global). Each is a CODE edit, so the gate does not fire and the dependent is
    # re-checked; every case asserts byte-identical-to-full, the soundness backstop.
    def write_state_holder(dir, assignment)
      reader = assignment.split(" = ").first
      base = File.join(dir, "base.rb")
      File.write(base, <<~RUBY)
        # note
        class Base
          #{assignment}
          def read
            #{reader}
          end
        end
      RUBY
      unless File.exist?(File.join(dir, "consumer.rb"))
        File.write(File.join(dir, "consumer.rb"), "class Consumer < Base\n  def use\n    read\n  end\nend\n")
      end
      base
    end

    {
      "a cross-file constant value" => ["CONST = 1", "CONST = 2"],
      "a class ivar write" => ["@field = 1", "@field = 2"],
      "a class cvar write" => ["@@shared = 1", "@@shared = 2"],
      "a program global write" => ["$g = 1", "$g = 2"]
    }.each do |desc, (before, after)|
      it "stays byte-identical to a full run when #{desc} changes (gate declines a code edit)" do
        Dir.mktmpdir do |dir|
          write_state_holder(dir, before)
          session = session_for(configuration(dir))
          session.baseline

          write_state_holder(dir, after)
          recheck = session.recheck

          # A code edit → the gate declines → the merged result still equals a full re-analysis.
          expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        end
      end
    end

    it "disables the gate when a comment-ingesting plugin (inline-RBS) is configured" do
      # inline-RBS reads comments as types, so a comment edit could change a cross-file signature the code
      # fingerprint ignores — the gate must fall back to today's full closure. Tested at the gate logic so it
      # does not depend on the plugin gem being on the load path.
      inline = Rigor::Configuration.new("paths" => ["x"], "plugins" => [{ "gem" => "rigor-rbs-inline" }])
      ordinary = Rigor::Configuration.new("paths" => ["x"], "plugins" => ["rigor-sorbet"])

      expect(described_class.new(configuration: inline).send(:comment_ingesting_plugin_loaded?)).to be(true)
      expect(described_class.new(configuration: ordinary).send(:comment_ingesting_plugin_loaded?)).to be(false)

      # With the gate disabled, EVERY changed file is unstable (dependents never skipped), even one whose code
      # fingerprint matched.
      session = described_class.new(configuration: inline)
      session.instance_variable_set(:@seed_bundles, { "a.rb" => { code_fingerprint: "fp" } })
      expect(session.send(:declaration_unstable, ["a.rb"], { "a.rb" => "fp" })).to eq(["a.rb"])
    end
  end
end
