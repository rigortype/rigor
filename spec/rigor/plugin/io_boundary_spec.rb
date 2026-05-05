# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Rigor::Plugin::IoBoundary do
  let(:tmpdir) { Dir.mktmpdir("rigor-io-boundary-spec-") }
  let(:policy) { Rigor::Plugin::TrustPolicy.new(allowed_read_roots: [tmpdir]) }
  let(:boundary) { described_class.new(policy: policy, plugin_id: "demo") }

  after { FileUtils.rm_rf(tmpdir) }

  describe "#read_file" do
    it "returns the file's bytes when the path is inside an allowed root" do
      path = File.join(tmpdir, "data.txt")
      File.write(path, "hello")

      expect(boundary.read_file(path)).to eq("hello")
    end

    it "denies a path outside every allowed read root" do
      expect { boundary.read_file("/etc/hosts") }.to raise_error(Rigor::Plugin::AccessDeniedError) do |e|
        expect(e.reason).to eq(:read_outside_scope)
        expect(e.resource).to eq("/etc/hosts")
      end
    end

    it "records a digest-keyed cache descriptor entry per read" do
      path = File.join(tmpdir, "data.txt")
      File.write(path, "hello")
      boundary.read_file(path)

      descriptor = boundary.cache_descriptor
      expect(descriptor.files.size).to eq(1)
      entry = descriptor.files.first
      expect(entry.path).to eq(File.expand_path(path))
      expect(entry.comparator).to eq(:digest)
      expect(entry.value).to eq(Digest::SHA256.hexdigest("hello"))
    end

    it "deduplicates repeat reads of the same path" do
      path = File.join(tmpdir, "data.txt")
      File.write(path, "hello")
      boundary.read_file(path)
      boundary.read_file(path)

      expect(boundary.cache_descriptor.files.size).to eq(1)
    end

    it "updates the entry when the file content changes between reads" do
      path = File.join(tmpdir, "data.txt")
      File.write(path, "v1")
      boundary.read_file(path)
      File.write(path, "v2")
      boundary.read_file(path)

      entry = boundary.cache_descriptor.files.first
      expect(entry.value).to eq(Digest::SHA256.hexdigest("v2"))
    end
  end

  describe "#open_url" do
    it "denies every URL while the network policy is :disabled" do
      expect { boundary.open_url("https://example.invalid/api") }.to raise_error(
        Rigor::Plugin::AccessDeniedError
      ) do |e|
        expect(e.reason).to eq(:network_disabled)
        expect(e.resource).to eq("https://example.invalid/api")
      end
    end
  end

  describe "#cache_descriptor" do
    it "is empty before any reads happen" do
      expect(boundary.cache_descriptor.files).to be_empty
    end

    it "returns a fresh frozen Descriptor that does not share state with the boundary" do
      path = File.join(tmpdir, "data.txt")
      File.write(path, "hello")
      boundary.read_file(path)

      first = boundary.cache_descriptor
      File.write(File.join(tmpdir, "other.txt"), "more")
      boundary.read_file(File.join(tmpdir, "other.txt"))
      second = boundary.cache_descriptor

      expect(first.files.size).to eq(1)
      expect(second.files.size).to eq(2)
      expect(first).to be_frozen
    end
  end
end
