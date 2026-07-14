# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-46 — the incremental analyzer's cross-process per-file state store.
RSpec.describe Rigor::Cache::IncrementalSnapshot do
  def diagnostic(path)
    Rigor::Analysis::Diagnostic.new(path: path, line: 1, column: 1, message: "m", severity: :warning, rule: "x")
  end

  def sample_payload
    described_class::Payload.new(
      cache: { "a.rb" => [diagnostic("a.rb")], "b.rb" => [] },
      sources: { "a.rb" => Set["b.rb"] },
      digests: { "a.rb" => "sha-a", "b.rb" => "sha-b" },
      analyzed: ["a.rb", "b.rb"],
      symbol_sources: { "a.rb" => { "b.rb" => Set["Foo#bar"] } },
      ancestry_sources: { "a.rb" => Set.new },
      symbol_fingerprints: { "b.rb" => { "Foo#bar" => "abc123" } },
      missing: { "a.rb" => Set["toplevel:helper"] },
      class_decls: { "b.rb" => Set["Foo"] },
      seed_bundles: { "b.rb" => { digest: "sha-b", classes: { "Foo" => nil }, methods: {} } },
      plugin_fact_digest: "fact-digest-abc"
    )
  end

  it "round-trips a payload under a matching fingerprint" do
    Dir.mktmpdir do |dir|
      snapshot = described_class.new(root: dir)
      expect(snapshot.save(fingerprint: "fp1", payload: sample_payload)).to be(true)

      loaded = snapshot.load(fingerprint: "fp1")
      expect(loaded.analyzed).to eq(["a.rb", "b.rb"])
      expect(loaded.sources).to eq("a.rb" => Set["b.rb"])
      expect(loaded.digests).to eq("a.rb" => "sha-a", "b.rb" => "sha-b")
      # Diagnostics survive Marshal round-trip structurally.
      expect(loaded.cache["a.rb"].map(&:to_h)).to eq([diagnostic("a.rb").to_h])
      expect(loaded.cache["b.rb"]).to eq([])
    end
  end

  it "round-trips the ADR-85 WD2 seed_bundles section" do
    Dir.mktmpdir do |dir|
      snapshot = described_class.new(root: dir)
      snapshot.save(fingerprint: "fp1", payload: sample_payload)
      loaded = snapshot.load(fingerprint: "fp1")
      expect(loaded.seed_bundles).to eq("b.rb" => { digest: "sha-b", classes: { "Foo" => nil }, methods: {} })
    end
  end

  it "round-trips the ADR-88 WD1 plugin_fact_digest" do
    Dir.mktmpdir do |dir|
      snapshot = described_class.new(root: dir)
      snapshot.save(fingerprint: "fp1", payload: sample_payload)
      loaded = snapshot.load(fingerprint: "fp1")
      expect(loaded.plugin_fact_digest).to eq("fact-digest-abc")
    end
  end

  it "ignores a schema-8 snapshot (pre-ADR-88: no plugin_fact_digest), loading nil for a cold rebuild" do
    Dir.mktmpdir do |dir|
      snapshot = described_class.new(root: dir)
      # A schema-8 blob (a pre-ADR-88 build) carries no `plugin_fact_digest`. Mis-reading it as a schema-9
      # payload would leave the field nil, which reads as "no fact surface" and could reuse a snapshot across a
      # plugin sig/catalog edit. The SCHEMA gate must discard it for a clean cold rebuild instead.
      old = Marshal.dump(
        schema: 8, fingerprint: "fp1", cache: {}, sources: {}, digests: {}, analyzed: [],
        symbol_sources: {}, ancestry_sources: {}, symbol_fingerprints: {}, missing: {}, class_decls: {},
        seed_bundles: { "a.rb" => { digest: "sha-a", code_fingerprint: "cf" } }
      )
      FileUtils.mkdir_p(File.dirname(snapshot.path))
      File.binwrite(snapshot.path, Zlib::Deflate.deflate(old))
      expect(snapshot.load(fingerprint: "fp1")).to be_nil
    end
  end

  it "ignores a snapshot written under an older schema, loading nil for a clean cold rebuild (ADR-85 SCHEMA bump)" do
    Dir.mktmpdir do |dir|
      snapshot = described_class.new(root: dir)
      # A pre-#85 (schema 5) blob has no seed_bundles section. It must load as nil — a clean cold rebuild —
      # not be mis-folded as a #85 payload with the field defaulted.
      old = Marshal.dump(
        schema: 5, fingerprint: "fp1", cache: {}, sources: {}, digests: {}, analyzed: [],
        symbol_sources: {}, ancestry_sources: {}, symbol_fingerprints: {}, missing: {}, class_decls: {}
      )
      FileUtils.mkdir_p(File.dirname(snapshot.path))
      File.binwrite(snapshot.path, Zlib::Deflate.deflate(old))
      expect(snapshot.load(fingerprint: "fp1")).to be_nil
    end
  end

  it "ignores a schema-7 snapshot (pre-B1: bundles carry no code_fingerprint), loading nil for a cold rebuild" do
    Dir.mktmpdir do |dir|
      snapshot = described_class.new(root: dir)
      # A schema-7 blob (written by a #87-era build) has seed bundles WITHOUT the B1 `code_fingerprint`
      # field. Mis-reading it would make `declaration_stable?` compare against nil forever (gate inert) —
      # the SCHEMA gate must instead discard it for a clean cold rebuild.
      old = Marshal.dump(
        schema: 7, fingerprint: "fp1", cache: {}, sources: {}, digests: {}, analyzed: [],
        symbol_sources: {}, ancestry_sources: {}, symbol_fingerprints: {}, missing: {}, class_decls: {},
        seed_bundles: { "a.rb" => { digest: "sha-a" } }
      )
      FileUtils.mkdir_p(File.dirname(snapshot.path))
      File.binwrite(snapshot.path, Zlib::Deflate.deflate(old))
      expect(snapshot.load(fingerprint: "fp1")).to be_nil
    end
  end

  it "returns nil when the fingerprint does not match (config / gem / version drift)" do
    Dir.mktmpdir do |dir|
      snapshot = described_class.new(root: dir)
      snapshot.save(fingerprint: "fp1", payload: sample_payload)

      expect(snapshot.load(fingerprint: "fp2")).to be_nil
    end
  end

  it "returns nil when no snapshot has been written" do
    Dir.mktmpdir do |dir|
      expect(described_class.new(root: dir).load(fingerprint: "fp1")).to be_nil
    end
  end

  it "returns nil (never raises) on a corrupt snapshot file" do
    Dir.mktmpdir do |dir|
      snapshot = described_class.new(root: dir)
      snapshot.save(fingerprint: "fp1", payload: sample_payload)
      File.binwrite(snapshot.path, "not a marshal blob")

      expect(snapshot.load(fingerprint: "fp1")).to be_nil
    end
  end

  it "returns false (never raises) when the root is unwritable" do
    snapshot = described_class.new(root: "/proc/nonexistent-rigor-root-#{Process.pid}")
    expect(snapshot.save(fingerprint: "fp1", payload: sample_payload)).to be(false)
  end

  describe ".fingerprint" do
    it "returns a SHA256 hex string" do
      conf = Rigor::Configuration.new("paths" => [])
      fp = described_class.fingerprint(configuration: conf, roots: ["lib"])
      expect(fp).to be_a(String)
      expect(fp.size).to eq(64)
    end

    it "returns nil on error (e.g. roots containing an object that raises on to_s)" do
      bad_root = Object.new
      bad_root.define_singleton_method(:to_s) { raise "oops" }
      conf = Rigor::Configuration.new("paths" => [])
      expect(described_class.fingerprint(configuration: conf, roots: [bad_root])).to be_nil
    end
  end

  describe ".digest_file_if_present" do
    it "returns 'absent' for a nonexistent file" do
      result = described_class.send(:digest_file_if_present, "/rigor-test-nonexistent-file")
      expect(result).to eq("absent")
    end
  end

  describe ".digest_signature_paths" do
    it "returns a hex string for nil paths" do
      result = described_class.send(:digest_signature_paths, nil)
      expect(result).to be_a(String)
      expect(result.size).to eq(64)
    end

    it "returns a hex string for empty array paths" do
      result = described_class.send(:digest_signature_paths, [])
      expect(result).to be_a(String)
      expect(result.size).to eq(64)
    end

    it "digests actual RBS files under a real directory" do
      Dir.mktmpdir("rigor-rbs-test-") do |dir|
        File.write(File.join(dir, "foo.rbs"), "class Foo; end")
        File.write(File.join(dir, "bar.rbs"), "class Bar; end")
        sub = File.join(dir, "sub")
        Dir.mkdir(sub)
        File.write(File.join(sub, "baz.rbs"), "class Baz; end")
        result = described_class.send(:digest_signature_paths, [dir])
        expect(result).to be_a(String)
        expect(result.size).to eq(64)
        # Deterministic: same files produce same hash
        result2 = described_class.send(:digest_signature_paths, [dir])
        expect(result2).to eq(result)
      end
    end

    it "includes a non-directory entry as a literal path" do
      Dir.mktmpdir("rigor-rbs-lit-") do |dir|
        rbs = File.join(dir, "single.rbs")
        File.write(rbs, "class Single; end")
        # Pass the file path directly, not its directory
        result = described_class.send(:digest_signature_paths, [rbs])
        expect(result).to be_a(String)
        expect(result.size).to eq(64)
      end
    end
  end
end
