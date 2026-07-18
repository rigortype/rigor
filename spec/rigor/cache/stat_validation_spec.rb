# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "digest"
require "rigor/cache/descriptor"
require "rigor/cache/file_digest"
require "rigor/analysis/runner"
require "rigor/configuration"
require "rigor/cache/store"

# ADR-87 WD1 / WD5 — the stat-then-digest validation staleness battery. Each case asserts the freshness
# OUTCOME plus, implicitly, which path decided it: the stat short-circuit (unmoved tuple, no hash), the digest
# fallback (moved tuple / racy window, re-hash), or the strict digest-always override. The SHA-256 digest is
# the sole change AUTHORITY throughout; the stat tier only decides whether the digest needs recomputing.
RSpec.describe "ADR-87 stat-then-digest validation (WD5)" do
  let(:tmpdir) { Dir.mktmpdir("rigor-stat-validation-spec-") }
  let(:path) { File.join(tmpdir, "a.rb") }

  before { File.write(path, "value = 1\n") }
  after { FileUtils.rm_rf(tmpdir) }

  def ns(time)
    (time.tv_sec * 1_000_000_000) + time.tv_nsec
  end

  # Builds a `:stat` entry the way the runner does — inside a `with_run` scope so the recording instant is set.
  def stat_entry(digest: nil)
    Rigor::Cache::FileDigest.with_run do
      Rigor::Cache::Descriptor::FileEntry.stat(
        path: path, digest: digest || Digest::SHA256.file(path).hexdigest
      )
    end
  end

  def fresh?(entry, strict: false)
    Rigor::Cache::FileDigest.with_run(strict: strict) do
      Rigor::Cache::Descriptor.new(files: [entry]).fresh?
    end
  end

  it "packs digest + size + mtime_ns + ctime_ns + inode + recording-instant into a :stat value" do
    entry = stat_entry
    expect(entry.comparator).to eq(:stat)
    fields = entry.value.split
    expect(fields.size).to eq(6)
    expect(fields[0]).to eq(Digest::SHA256.file(path).hexdigest)
    expect(fields[1].to_i).to eq(File.size(path))
    st = File.stat(path)
    expect(fields[2].to_i).to eq(ns(st.mtime))
    expect(fields[4].to_i).to eq(st.ino)
  end

  # Case 1 — touch-only: the stat moves but the content is identical → FRESH (strictly fewer false
  # invalidations than today; a `touch` no longer forces a recompute-of-value).
  it "stays fresh after a touch (moved mtime, identical content)" do
    entry = stat_entry
    later = Time.now + 5
    File.utime(later, later, path)
    expect(fresh?(entry)).to be(true)
  end

  # Case 2 — ordinary edit → stale (moved tuple → re-hash → digest differs).
  it "goes stale on an ordinary content edit" do
    entry = stat_entry
    sleep 0.01
    File.write(path, "value = 22\n")
    expect(fresh?(entry)).to be(false)
  end

  # Case 3 — same-size edit → stale via mtime/ctime even though the size is unchanged.
  it "goes stale on a same-size content edit" do
    entry = stat_entry
    sleep 0.01
    File.write(path, "value = 9\n") # identical byte length, different content
    expect(File.size(path)).to eq(entry.value.split[1].to_i)
    expect(fresh?(entry)).to be(false)
  end

  # Case 4 — same-size edit whose mtime is spoofed back to the recorded value → stale via ctime, which
  # `utimes` cannot reset (defeating the tier needs root / clock manipulation, per the ADR's threat model).
  it "goes stale on a same-size edit with the mtime backdated to the recorded value" do
    entry = stat_entry
    recorded_mtime = File.mtime(path)
    sleep 0.01
    File.write(path, "value = 9\n")
    File.utime(recorded_mtime, recorded_mtime, path) # spoof mtime back; ctime still advanced
    expect(ns(File.mtime(path))).to eq(entry.value.split[2].to_i) # mtime truly restored
    expect(fresh?(entry)).to be(false)
  end

  # Case 5 — a racy entry (recorded mtime not strictly older than the recording instant) is ALWAYS re-hashed,
  # so the digest — not the stat tuple — decides. A crafted entry whose tuple matches the file but whose
  # digest is wrong is therefore STALE when racy and FRESH when non-racy, proving the racy guard forces the
  # re-hash a stat-trust would skip.
  it "re-hashes a racy entry even when its stat tuple still matches" do
    st = File.stat(path)
    tuple = "#{st.size} #{ns(st.mtime)} #{ns(st.ctime)} #{st.ino}"
    wrong_digest = "0" * 64

    racy = Rigor::Cache::Descriptor::FileEntry.new(
      path: path, comparator: :stat, value: "#{wrong_digest} #{tuple} #{ns(st.mtime)}"
    ) # recording instant == mtime → racy
    expect(fresh?(racy)).to be(false)

    non_racy = Rigor::Cache::Descriptor::FileEntry.new(
      path: path, comparator: :stat, value: "#{wrong_digest} #{tuple} #{ns(st.mtime) + 1_000_000_000}"
    ) # recording instant strictly after mtime → not racy → trusts stat
    expect(fresh?(non_racy)).to be(true)
  end

  # Case 6 — strict validation (config `cache.validation: digest` / `RIGOR_STRICT_VALIDATION=1`) ignores the
  # stat tuple entirely: a touch is fresh via the digest, and the env var wins even when the run scope was
  # opened non-strict.
  describe "strict validation" do
    it "validates by digest (touch stays fresh, edit goes stale) under with_run(strict: true)" do
      entry = stat_entry
      later = Time.now + 5
      File.utime(later, later, path)
      expect(fresh?(entry, strict: true)).to be(true) # digest unchanged

      File.write(path, "value = 3\n")
      expect(fresh?(entry, strict: true)).to be(false)
    end

    it "honours RIGOR_STRICT_VALIDATION=1 over a non-strict run scope" do
      stat_entry
      original = ENV.fetch("RIGOR_STRICT_VALIDATION", nil)
      ENV["RIGOR_STRICT_VALIDATION"] = "1"
      begin
        # A crafted entry whose tuple matches but digest is wrong would be trusted by the stat tier; strict
        # mode re-hashes and rejects it.
        st = File.stat(path)
        spoof = Rigor::Cache::Descriptor::FileEntry.new(
          path: path, comparator: :stat,
          value: "#{'0' * 64} #{st.size} #{ns(st.mtime)} #{ns(st.ctime)} #{st.ino} #{ns(st.mtime) + 1_000_000_000}"
        )
        expect(fresh?(spoof)).to be(false)
      ensure
        ENV["RIGOR_STRICT_VALIDATION"] = original
      end
    end
  end

  # #190 — the `auto` default resolves the run's strict flag per environment: strict in CI (where a fresh
  # checkout regenerates every stat tuple, so the stat tier can never short-circuit and stat-signature glob
  # slots would recompute every run), stat-first everywhere else. Detection is a pure function of the env
  # hash passed in, so no ENV mutation is needed; the suite's global `RIGOR_CI_DETECT=0` does not interfere
  # because these examples pass explicit hashes.
  describe "auto validation default (#190)" do
    def config(overrides = {})
      Rigor::Configuration.new("paths" => ["lib"], "cache" => overrides)
    end

    it "defaults cache_validation to auto" do
      expect(config.cache_validation).to eq("auto")
    end

    it "coerces an unrecognised value to auto" do
      expect(config("validation" => "sha1").cache_validation).to eq("auto")
    end

    it "resolves auto to non-strict outside CI" do
      expect(config.cache_validation_strict?({})).to be(false)
    end

    it "resolves auto to strict under a recognised provider and the generic CI catch-all" do
      expect(config.cache_validation_strict?({ "GITHUB_ACTIONS" => "true" })).to be(true)
      expect(config.cache_validation_strict?({ "CI" => "true" })).to be(true)
    end

    it "honours the RIGOR_CI_DETECT=0 kill switch" do
      expect(config.cache_validation_strict?({ "CI" => "true", "RIGOR_CI_DETECT" => "0" })).to be(false)
    end

    it "lets an explicit stat opt a persistent-workspace CI runner back into the stat floor" do
      expect(config("validation" => "stat").cache_validation_strict?({ "CI" => "true" })).to be(false)
    end

    it "keeps an explicit digest strict everywhere" do
      expect(config("validation" => "digest").cache_validation_strict?({})).to be(true)
    end
  end

  # WD5 end-to-end false-invalidation guard: a touch-only change (moved stat, identical content) between two
  # cache-backed runs stays a HIT — the second run serves the cached diagnostics without re-running the
  # whole-project discovery pass, and its diagnostics are byte-identical.
  describe "touch-only run stays a HIT end-to-end" do
    def write_project(dir)
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "a.rb"), "class Widget\n  def price\n    10\n  end\nend\n")
      File.write(File.join(lib, "b.rb"), "class Shop\n  def total\n    Widget.new.price\n  end\nend\n")
      lib
    end

    def build_runner(dir, cache_root)
      Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [File.join(dir, "lib")]),
        cache_store: Rigor::Cache::Store.new(root: cache_root), collect_stats: false
      )
    end

    it "serves the cached run after a touch, skipping re-analysis" do
      Dir.mktmpdir("rigor-stat-hit-") do |dir|
        lib = write_project(dir)
        cache_root = File.join(dir, ".rigor", "cache")

        allow(Rigor::Inference::ScopeIndexer).to receive(:discovered_project_index_for_paths).and_call_original
        cold = Dir.chdir(dir) { build_runner(dir, cache_root).run }
        expect(Rigor::Inference::ScopeIndexer).to have_received(:discovered_project_index_for_paths).once

        # Touch every project file — move mtime, content identical.
        later = Time.now + 10
        Dir.glob(File.join(lib, "*.rb")).each { |f| File.utime(later, later, f) }

        warm_runner = build_runner(dir, cache_root)
        warm = Dir.chdir(dir) { warm_runner.run }

        # No further discovery parse ⇒ the touched run was served from the ADR-45 cache (stat-then-digest
        # validated the moved-but-identical files as fresh).
        expect(Rigor::Inference::ScopeIndexer).to have_received(:discovered_project_index_for_paths).once
        expect(warm.diagnostics.map(&:to_h)).to eq(cold.diagnostics.map(&:to_h))
      end
    end
  end
end
