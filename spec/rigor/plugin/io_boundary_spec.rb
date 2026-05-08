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

    describe "with an :allowlist network policy (v0.1.2)" do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:fake_responses) { {} }
      let(:fake_http) do
        responses = fake_responses
        Class.new do
          define_method(:get) { |url, **_kwargs| responses.fetch(url) { raise "no fake response for #{url.inspect}" } }
        end.new
      end

      let(:allowlist_policy) do
        Rigor::Plugin::TrustPolicy.new(
          allowed_read_roots: [tmpdir],
          network_policy: :allowlist,
          allowed_url_hosts: %w[example.com]
        )
      end

      let(:allowlist_boundary) do
        described_class.new(policy: allowlist_policy, plugin_id: "demo", http_client: fake_http)
      end

      it "fetches an allowlisted URL through the injected client and returns its body" do
        fake_responses["https://example.com/foo"] = "payload"
        expect(allowlist_boundary.open_url("https://example.com/foo")).to eq("payload")
      end

      it "records a ConfigEntry keyed `url:<url>` with the SHA-256 of the response body" do
        fake_responses["https://example.com/foo"] = "payload"
        allowlist_boundary.open_url("https://example.com/foo")

        descriptor = allowlist_boundary.cache_descriptor
        expect(descriptor.configs.size).to eq(1)
        entry = descriptor.configs.first
        expect(entry.key).to eq("url:https://example.com/foo")
        expect(entry.value_hash).to eq(Digest::SHA256.hexdigest("payload"))
      end

      it "denies a URL whose host is not on the allowlist" do
        expect { allowlist_boundary.open_url("https://other.invalid/foo") }.to raise_error(
          Rigor::Plugin::AccessDeniedError
        ) do |e|
          expect(e.reason).to eq(:network_disabled)
          expect(e.resource).to eq("https://other.invalid/foo")
        end
      end

      it "denies a non-HTTPS URL even if the host is on the allowlist" do
        expect { allowlist_boundary.open_url("http://example.com/foo") }.to raise_error(
          Rigor::Plugin::AccessDeniedError
        ) do |e|
          expect(e.reason).to eq(:network_disabled)
        end
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
