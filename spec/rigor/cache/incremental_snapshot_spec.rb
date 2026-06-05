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
      missing: { "a.rb" => Set["toplevel:helper"] }
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
end
