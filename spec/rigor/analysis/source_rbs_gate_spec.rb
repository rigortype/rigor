# frozen_string_literal: true

require "spec_helper"
require "digest"
require "tmpdir"
require "fileutils"

# Issue #1536 — the incremental session's source-RBS gate, below the session: how a digest is bound to the
# bytes its seed bundle was built from, and what a run whose prepared registry disagrees with the gate's own
# synthesizer set does to the stamps. The end-to-end closure behaviour is in `incremental_session_spec.rb`.
RSpec.describe Rigor::Analysis::SourceRbsGate do
  let(:dir) { Dir.mktmpdir("rigor-source-rbs-gate-") }
  let(:path) { File.join(dir, "a.rb") }
  let(:configuration) { Rigor::Configuration.new("paths" => [dir]) }
  let(:gate) { described_class.new(configuration: configuration, cache_store: nil, plugin_requirer: nil) }
  # Echoes the file's bytes as its RBS, so every content change moves the digest.
  let(:synthesizer) { [Struct.new(:manifest).new(Struct.new(:id).new("echo")), ->(file) { File.read(file) }] }

  before { allow(gate).to receive(:synthesizers).and_return([synthesizer]) }
  after { FileUtils.rm_rf(dir) }

  def digest_now
    Rigor::Environment::SourceRbsSynthesis.digest([synthesizer], path, nil)
  end

  def bundle_for_current_bytes
    { digest: Digest::SHA256.file(path).hexdigest }
  end

  def registry_with(*ids)
    pairs = ids.map { |id| [Struct.new(:manifest).new(Struct.new(:id).new(id)), ->(_file) {}] }
    instance_double(Rigor::Plugin::Registry, source_rbs_synthesizers: pairs)
  end

  describe "#stamp" do
    it "binds a digest read before a save to nothing, and re-reads it from the bytes the bundle was built from" do
      File.write(path, "class A\nend\n")
      gate.moved?({}, [], [path], []) # the closure decision reads the pre-save bytes
      before_save = digest_now
      File.write(path, "class B\nend\n") # saved before the runner's discovery built the bundle

      stamped = gate.stamp(path => bundle_for_current_bytes)

      expect(stamped.fetch(path).fetch(:source_rbs_digest)).to eq(digest_now)
      expect(digest_now).not_to eq(before_save)
    end

    it "stores a digest as unknown when the bytes on disk never match the bundle's" do
      File.write(path, "class A\nend\n")

      stamped = gate.stamp(path => { digest: "0" * 64 })

      expect(stamped.fetch(path)).to include(source_rbs_digest: nil)
    end

    it "keeps the digest a reused bundle already carries" do
      File.write(path, "class A\nend\n")
      reused = bundle_for_current_bytes.merge(source_rbs_digest: "kept")

      expect(gate.stamp(path => reused).fetch(path)).to be(reused)
    end
  end

  describe "#verify" do
    before do
      File.write(path, "class A\nend\n")
      gate.moved?({}, [], [path], [])
    end

    let(:stamped) { gate.stamp(path => bundle_for_current_bytes) }

    it "trusts a run whose prepared registry declares the synthesizers the gate digested with" do
      expect(gate.verify(registry_with("echo"), stamped)).to eq(stamped)
      expect(gate).not_to be_untrusted
    end

    it "turns untrusted, and stamps every digest unknown, when the prepared registry declares another set" do
      kept = gate.verify(registry_with("echo", "built-in-prepare"), stamped)

      expect(gate).to be_untrusted
      expect(kept.fetch(path)).to include(source_rbs_digest: nil)
      expect(gate.stamp(path => bundle_for_current_bytes).fetch(path)).to include(source_rbs_digest: nil)
      expect(gate.moved?(kept, [path], [], [])).to be(true)
    end

    it "distrusts a run whose prepared registry could not be built" do
      gate.verify(nil, stamped)

      expect(gate).to be_untrusted
    end
  end

  it "has nothing to distrust in a session that never digested a file" do
    idle = described_class.new(configuration: configuration, cache_store: nil, plugin_requirer: nil)

    expect(idle.verify(nil, { path => { source_rbs_digest: "x" } })).to eq(path => { source_rbs_digest: "x" })
    expect(idle).not_to be_untrusted
  end
end
