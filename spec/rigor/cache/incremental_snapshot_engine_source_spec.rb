# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/incremental_session"
require "rigor/cache/engine_source"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

# Issue #289 — `rigor check --incremental` had the #285 defect that PR #288 fixed for the run-result and
# mutation caches: the global snapshot fingerprint carried `Rigor::VERSION` and nothing derived from the
# engine's source, so on a checkout a warm recheck served diagnostics a pre-edit analyzer had computed.
#
# The defect is not "the fingerprint string omits a slot" — it is that the recheck comes back WARM after an
# engine edit, having re-analysed nothing. So the examples here drive a real {Analysis::IncrementalSession}
# against a real on-disk snapshot and assert on the session's own warm/cold verdict.
#
# The engine tree is relocated to a temporary directory throughout, because the alternative is a spec that
# edits this checkout's own `lib/`. `engine_source_spec.rb` pins the un-relocated default.
RSpec.describe "incremental snapshot invalidation on an engine-source edit" do
  # The engine file an example edits — the very path whose edits used to be invisible.
  def engine_file(root)
    File.join(root, "lib", "rigor", "inference", "narrowing.rb")
  end

  def write_engine(dir, body)
    root = File.join(dir, "engine")
    FileUtils.mkdir_p(File.dirname(engine_file(root)))
    File.write(engine_file(root), body)
    allow(Rigor::Cache::EngineSource).to receive(:root).and_return(root)
    root
  end

  # Two files, so the recheck has unchanged work it could wrongly serve. `Shop#total` carries a stable
  # `Rigor.dump_type` so the diagnostics compared below are never JUST the run-level gem-RBS-coverage
  # row — an oracle equality on that alone would hold on two crash-coincidental "internal analyzer
  # error" lists exactly as readily as on a real result (issue #683 review).
  def write_project(dir)
    lib = File.join(dir, "project", "lib")
    FileUtils.mkdir_p(lib)
    File.write(File.join(lib, "a.rb"), "class Widget\n  def price\n    10\n  end\nend\n")
    File.write(File.join(lib, "b.rb"),
               "class Shop\n  def total\n    Rigor.dump_type(1)\n    Widget.new.price\n  end\nend\n")
    lib
  end

  def shared_environment
    @shared_environment ||= Rigor::Environment.for_project
  end

  # One simulated `rigor check --incremental` process: a fresh memo (a real process computes the digest
  # once at boot), a fresh fingerprint, a fresh session, and the snapshot read back off disk.
  # @return [Array(Array<Diagnostic>, Boolean)] the session's diagnostics and its warm verdict.
  def check(dir, lib, cache_root)
    Rigor::Cache::EngineSource.reset_process_identity!
    Dir.chdir(dir) do
      configuration = Rigor::Configuration.new("paths" => [lib])
      session = Rigor::Analysis::IncrementalSession.new(
        configuration: configuration, paths: [lib], environment: shared_environment
      )
      guarded_run_incremental(
        session,
        snapshot: Rigor::Cache::IncrementalSnapshot.new(root: cache_root),
        fingerprint: Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: [lib])
      )
    end
  end

  it "RECHECKS COLD after an engine-source edit, instead of replaying the stale diagnostics warm" do
    Dir.mktmpdir("rigor-engine-source-incremental-") do |dir|
      lib = write_project(dir)
      engine = write_engine(dir, "# v1\n")
      cache_root = File.join(dir, ".rigor", "cache")

      cold, warm_flag = check(dir, lib, cache_root)
      expect(warm_flag).to be(false)

      # No edit: the snapshot is useful — the second run is SERVED, not recomputed.
      served, warm_flag = check(dir, lib, cache_root)
      expect(warm_flag).to be(true)
      expect(served.map(&:to_h)).to eq(cold.map(&:to_h))

      # The acceptance criterion: an engine edit alone — no project file, no config, no `sig/` moved —
      # makes the next recheck run cold.
      File.write(engine_file(engine), "# v2\n")
      after, warm_flag = check(dir, lib, cache_root)
      expect(warm_flag).to be(false)
      expect(after.map(&:to_h)).to eq(cold.map(&:to_h))

      # And the post-edit snapshot is itself reusable: the fingerprint moved, it did not stop working.
      _, warm_flag = check(dir, lib, cache_root)
      expect(warm_flag).to be(true)
    end
  end

  # The `Unavailable` contract, and the failure mode specific to THIS cache: `.fingerprint` answers nil on
  # any error, and a nil that reached `#save` as a key would be matched by the next equally-nil run — the
  # stale serve, rebuilt out of the disable path. {IncrementalSession} guards the save, so nothing is
  # written; this pins that, because the guard lives in another class.
  it "DISABLES the snapshot when the engine cannot be identified, writing no nil-keyed blob to match later" do
    Dir.mktmpdir("rigor-engine-source-incremental-") do |dir|
      lib = write_project(dir)
      cache_root = File.join(dir, ".rigor", "cache")
      allow(Rigor::Cache::EngineSource)
        .to receive(:identity).and_raise(Rigor::Cache::EngineSource::Unavailable)

      2.times do
        _, warm_flag = check(dir, lib, cache_root)
        expect(warm_flag).to be(false)
      end

      expect(Rigor::Cache::IncrementalSnapshot.fingerprint(
               configuration: Rigor::Configuration.new("paths" => [lib]), roots: [lib]
             )).to be_nil
      expect(File.exist?(File.join(cache_root, "incremental", "snapshot.bin"))).to be(false)
    end
  end

  describe ".fingerprint" do
    def fingerprint_in(dir, lib)
      Rigor::Cache::EngineSource.reset_process_identity!
      Dir.chdir(dir) do
        Rigor::Cache::IncrementalSnapshot.fingerprint(
          configuration: Rigor::Configuration.new("paths" => [lib]), roots: [lib]
        )
      end
    end

    it "moves when the engine source moves, on a checkout" do
      Dir.mktmpdir("rigor-engine-source-incremental-") do |dir|
        lib = write_project(dir)
        engine = write_engine(dir, "# v1\n")
        before = fingerprint_in(dir, lib)

        File.write(engine_file(engine), "# v2\n")

        expect(fingerprint_in(dir, lib)).not_to eq(before)
      end
    end

    # A released gem adds no part at all, so its fingerprint is the pre-#289 one byte for byte — which is
    # what lets an upgrading user keep their warm snapshot. Asserted as the property that guarantee rests
    # on: for a version-pinned tree the fingerprint cannot vary with engine source, because it never reads
    # it. (`identity` answering nil is the contract `engine_source_spec.rb` pins for the pinned layout.)
    it "is independent of engine source for a version-pinned tree, so a released gem's key is untouched" do
      Dir.mktmpdir("rigor-engine-source-incremental-") do |dir|
        lib = write_project(dir)
        engine = write_engine(dir, "# v1\n")
        allow(Rigor::Cache::EngineSource).to receive(:version_pinned?).and_return(true)
        before = fingerprint_in(dir, lib)

        File.write(engine_file(engine), "# v2\n")

        expect(fingerprint_in(dir, lib)).to eq(before)
        # …and it is genuinely a different key from the checkout's, not the same string by accident.
        allow(Rigor::Cache::EngineSource).to receive(:version_pinned?).and_return(false)
        expect(fingerprint_in(dir, lib)).not_to eq(before)
      end
    end
  end
end
