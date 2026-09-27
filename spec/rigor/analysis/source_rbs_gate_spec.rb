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
    it "stamps the closure's reading when the bundle was built from the same bytes" do
      File.write(path, "class A\nend\n")
      gate.moved?({}, [], [path], [])

      stamped = gate.stamp({ path => bundle_for_current_bytes })

      expect(stamped.fetch(path)).to include(source_rbs_digest: digest_now)
      expect(gate.unbound).to be_empty
    end

    it "stamps unknown, without re-reading, a file saved after the closure was decided" do
      # The readers' cached answers predate the save, so the post-save digest must not stand for them.
      File.write(path, "class A\nend\n")
      gate.moved?({}, [], [path], [])
      File.write(path, "class B\nend\n")

      stamped = gate.stamp({ path => bundle_for_current_bytes })

      expect(stamped.fetch(path)).to include(source_rbs_digest: nil)
      expect(gate.unbound).to eq(Set[path])
    end

    it "stamps unknown a bundle this run built without a reading, unless every file was re-analysed" do
      File.write(path, "class A\nend\n")

      expect(gate.stamp({ path => bundle_for_current_bytes }).fetch(path)).to include(source_rbs_digest: nil)
      expect(gate.stamp({ path => bundle_for_current_bytes }, whole_project: true).fetch(path))
        .to include(source_rbs_digest: digest_now)
    end

    it "re-stamps an unknown digest once a run can vouch for it, and only then" do
      File.write(path, "class A\nend\n")
      unknown = bundle_for_current_bytes.merge(source_rbs_digest: nil)

      expect(gate.stamp({ path => unknown }).fetch(path)).to be(unknown)
      expect(gate.stamp({ path => unknown }, whole_project: true).fetch(path))
        .to include(source_rbs_digest: digest_now)
      gate.moved?({ path => unknown }, [path], [], [])
      expect(gate.stamp({ path => unknown }).fetch(path)).to include(source_rbs_digest: digest_now)
    end

    it "keeps the digest a reused bundle already carries" do
      File.write(path, "class A\nend\n")
      reused = bundle_for_current_bytes.merge(source_rbs_digest: "kept")

      expect(gate.stamp({ path => reused }).fetch(path)).to be(reused)
    end
  end

  describe "#verify" do
    before do
      File.write(path, "class A\nend\n")
      gate.moved?({}, [], [path], [])
    end

    let(:stamped) { gate.stamp({ path => bundle_for_current_bytes }) }

    it "trusts a run whose prepared registry declares the synthesizers the gate digested with" do
      expect(gate.verify(registry_with("echo"), stamped)).to eq(stamped)
      expect(gate).not_to be_untrusted
    end

    it "turns untrusted, and stamps every digest unknown, when the prepared registry declares another set" do
      kept = gate.verify(registry_with("echo", "built-in-prepare"), stamped)

      expect(gate).to be_untrusted
      expect(kept.fetch(path)).to include(source_rbs_digest: nil)
      expect(gate.stamp({ path => bundle_for_current_bytes }).fetch(path)).to include(source_rbs_digest: nil)
      expect(gate.moved?(kept, [path], [], [])).to be(true)
    end

    it "distrusts a run whose prepared registry could not be built" do
      gate.verify(nil, stamped)

      expect(gate).to be_untrusted
    end
  end

  it "verifies a session that has not read a file yet, since a stamp an earlier process wrote is at stake" do
    idle = described_class.new(configuration: configuration, cache_store: nil, plugin_requirer: nil)
    allow(idle).to receive(:synthesizers).and_return([synthesizer])

    kept = idle.verify(registry_with("echo", "built-in-prepare"), { path => { source_rbs_digest: "x" } })

    expect(idle).to be_untrusted
    expect(kept.fetch(path)).to include(source_rbs_digest: nil)
  end
end
