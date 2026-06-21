# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-46 — the incremental analyzer's cross-process per-file state store.
RSpec.describe Rigor::Cache::IncrementalSnapshot do
  def diagnostic(path)
    Rigor::Analysis::Diagnostic.new(path: path, line: 1, column: 0, message: "m", severity: :warning, rule: "x")
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
      class_decls: { "b.rb" => Set["Foo"] }
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
