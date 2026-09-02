# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "net/http"

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

    it "records a stat-then-digest (:stat) cache descriptor entry per read" do
      path = File.join(tmpdir, "data.txt")
      File.write(path, "hello")
      boundary.read_file(path)

      descriptor = boundary.cache_descriptor
      expect(descriptor.files.size).to eq(1)
      entry = descriptor.files.first
      expect(entry.path).to eq(File.expand_path(path))
      # ADR-87 WD1 — the validation-only boundary descriptor rides the stat-then-digest `:stat` tier; the
      # content digest is the first field of the packed value.
      expect(entry.comparator).to eq(:stat)
      expect(entry.value.split.first).to eq(Digest::SHA256.hexdigest("hello"))
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
      expect(entry.value.split.first).to eq(Digest::SHA256.hexdigest("v2"))
    end
  end

  # ADR-45 WD1 (#577) — a read that finds nothing is an existence probe, and the absence it observed is a
  # dependency: a value computed on "the schema is missing" must invalidate once the schema appears. The
  # boundary records that as an absence row; the bounds below (scope first, not-there outcomes only, content
  # rows kept over absence rows) keep the recording deliberate.
  describe "#read_file on a path that does not exist (ADR-45 WD1, #577)" do
    it "raises ENOENT and records an absence row that is fresh while the path is missing, stale once it appears" do
      path = File.join(tmpdir, "db", "schema.rb")

      expect { boundary.read_file(path) }.to raise_error(Errno::ENOENT)

      descriptor = boundary.cache_descriptor
      expect(descriptor.files.size).to eq(1)
      entry = descriptor.files.first
      expect(entry.path).to eq(File.expand_path(path))
      expect(entry).to be_absent
      expect(descriptor.fresh?).to be(true)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "create_table")
      expect(descriptor.fresh?).to be(false)
    end

    it "records the absence when a parent component is a regular file (ENOTDIR)" do
      File.write(File.join(tmpdir, "db"), "not a directory")
      path = File.join(tmpdir, "db", "schema.rb")

      expect { boundary.read_file(path) }.to raise_error(Errno::ENOTDIR)
      expect(boundary.cache_descriptor.files.map(&:absent?)).to eq([true])
    end

    it "lets a later successful read of the same path replace the absence row with the content row" do
      path = File.join(tmpdir, "late.txt")
      expect { boundary.read_file(path) }.to raise_error(Errno::ENOENT)
      File.write(path, "arrived")
      boundary.read_file(path)

      files = boundary.cache_descriptor.files
      expect(files.size).to eq(1)
      expect(files.first.comparator).to eq(:stat)
      expect(files.first.value.split.first).to eq(Digest::SHA256.hexdigest("arrived"))
    end

    it "keeps an earlier content row over a later missing-read of the same path" do
      path = File.join(tmpdir, "gone.txt")
      File.write(path, "was here")
      boundary.read_file(path)
      File.unlink(path)
      expect { boundary.read_file(path) }.to raise_error(Errno::ENOENT)

      files = boundary.cache_descriptor.files
      expect(files.size).to eq(1)
      expect(files.first.comparator).to eq(:stat)
      # The content row is the one that reads stale while the file is gone — the conservative direction.
      expect(boundary.cache_descriptor.fresh?).to be(false)
    end

    it "records nothing for a missing path outside the trusted-read scope (the policy check comes first)" do
      expect { boundary.read_file("/definitely/not/under/the/tmpdir.txt") }
        .to raise_error(Rigor::Plugin::AccessDeniedError)
      expect(boundary.cache_descriptor.files).to be_empty
    end

    it "records nothing for a path that exists but is not a readable file (EISDIR is a failure, not a probe)" do
      dir = File.join(tmpdir, "schema.rb")
      FileUtils.mkdir_p(dir)

      expect { boundary.read_file(dir) }.to raise_error(Errno::EISDIR)
      expect(boundary.cache_descriptor.files).to be_empty
    end
  end

  # ADR-45 WD1b (#613) — WD1 records the absence at the READ, which never happens on the projects it was
  # written for: the prevailing plugin shape gates the read on `File.file?` / `File.directory?` first, and a
  # probe through `File` records nothing. These predicates are the same probe with the row attached.
  describe "#file? / #directory? (ADR-45 WD1b, #613)" do
    it "answers true for an existing file and records a presence row, stale once the file is gone" do
      path = File.join(tmpdir, "sidekiq.yml")
      File.write(path, ":queues:\n")

      expect(boundary.file?(path)).to be(true)

      descriptor = boundary.cache_descriptor
      expect(descriptor.files.map { |e| [e.path, e.comparator, e.value] })
        .to eq([[File.expand_path(path), :exists, Rigor::Cache::Descriptor::FileEntry::PRESENT]])
      expect(descriptor.fresh?).to be(true)

      File.unlink(path)
      expect(descriptor.fresh?).to be(false)
    end

    it "answers false for a missing file and records the absence row, stale once the file appears" do
      path = File.join(tmpdir, "config", "sidekiq.yml")

      expect(boundary.file?(path)).to be(false)

      descriptor = boundary.cache_descriptor
      expect(descriptor.files.map(&:absent?)).to eq([true])
      expect(descriptor.fresh?).to be(true)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, ":queues:\n")
      expect(descriptor.fresh?).to be(false)
    end

    it "records nothing when the path exists but is not what the probe asked for" do
      # The probe observed neither a usable file nor an absence — `#read_file`'s EISDIR bound in probe form.
      # An absence row here would read stale on every run while the directory stands.
      dir = File.join(tmpdir, "sidekiq.yml")
      FileUtils.mkdir_p(dir)

      expect(boundary.file?(dir)).to be(false)
      expect(boundary.cache_descriptor.files).to be_empty
    end

    it "records a presence row for a discovery root that exists, so deleting the root invalidates" do
      root = File.join(tmpdir, "app", "models")
      FileUtils.mkdir_p(root)

      expect(boundary.directory?(root)).to be(true)

      descriptor = boundary.cache_descriptor
      expect(descriptor.files.map(&:value)).to eq([Rigor::Cache::Descriptor::FileEntry::PRESENT])
      expect(descriptor.fresh?).to be(true)

      FileUtils.rm_rf(root)
      expect(descriptor.fresh?).to be(false)
    end

    it "records an absence row for a discovery root that does not exist yet" do
      root = File.join(tmpdir, "app", "models")

      expect(boundary.directory?(root)).to be(false)
      expect(boundary.cache_descriptor.files.map(&:absent?)).to eq([true])

      FileUtils.mkdir_p(root)
      expect(boundary.cache_descriptor.fresh?).to be(false)
    end

    it "answers truthfully outside the trusted-read scope and records nothing there" do
      # The predicates REPLACE a bare `File.file?` in plugin code, so they must not change what the plugin
      # does — only what it records. The policy gates the row, not the answer.
      expect(boundary.file?("/etc/hosts")).to eq(File.file?("/etc/hosts"))
      expect(boundary.directory?("/definitely/not/under/the/tmpdir")).to be(false)
      expect(boundary.cache_descriptor.files).to be_empty
    end

    it "lets a later read replace the probe's presence row with the content row" do
      path = File.join(tmpdir, "sidekiq.yml")
      File.write(path, ":queues:\n")

      boundary.file?(path)
      boundary.read_file(path)

      files = boundary.cache_descriptor.files
      expect(files.size).to eq(1)
      expect(files.first.comparator).to eq(:stat)
    end

    it "keeps the first existence row when a later probe of the same path disagrees" do
      path = File.join(tmpdir, "sidekiq.yml")

      expect(boundary.file?(path)).to be(false)
      File.write(path, ":queues:\n")
      expect(boundary.file?(path)).to be(true)

      # The file moved under the analysis. The row that stands describes the world the earlier decision was
      # shaped on, and it reads stale now — a recompute next run, never a wrong hit.
      files = boundary.cache_descriptor.files
      expect(files.map(&:absent?)).to eq([true])
      expect(boundary.cache_descriptor.fresh?).to be(false)
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

    describe "with an :allowlist network policy (v0.1.2)" do
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

  # The real-`Net::HTTP` wrapper the boundary injects-over in every other test (a fake `#get`); exercised here with
  # stubbed transport so the success / non-success / oversize-body branches and their reason codes have a unit safety
  # net without touching the network.
  describe Rigor::Plugin::DefaultHttpClient do
    subject(:client) { described_class.new }

    let(:url) { "https://example.test/data.json" }
    let(:http) { instance_double(Net::HTTP) }

    before { allow(Net::HTTP).to receive(:start).and_yield(http) }

    # Real response objects so `#is_a?(Net::HTTPSuccess)` and `#code` are genuine; only the socket-backed `#read_body`
    # needs stubbing.
    def respond_with(response)
      allow(http).to receive(:request_get).and_yield(response)
    end

    it "returns the streamed body concatenated on a successful response" do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      allow(response).to receive(:read_body) { |&block| %w[foo bar].each(&block) }
      respond_with(response)

      expect(client.get(url, timeout: 1, max_bytes: 1000)).to eq("foobar")
    end

    it "raises url_fetch_failed on a non-success response, naming the status and url" do
      respond_with(Net::HTTPForbidden.new("1.1", "403", "Forbidden"))

      expect { client.get(url, timeout: 1, max_bytes: 1000) }
        .to raise_error(Rigor::Plugin::AccessDeniedError) do |e|
          expect(e.reason).to eq(:url_fetch_failed)
          expect(e.resource).to eq(url)
          expect(e.message).to include("403").and include(url)
        end
    end

    it "raises url_body_too_large once the streamed body exceeds max_bytes" do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      allow(response).to receive(:read_body) { |&block| %w[aaaa bbbb].each(&block) }
      respond_with(response)

      expect { client.get(url, timeout: 1, max_bytes: 5) }
        .to raise_error(Rigor::Plugin::AccessDeniedError) do |e|
          expect(e.reason).to eq(:url_body_too_large)
          expect(e.resource).to eq(url)
          expect(e.message).to include("5")
        end
    end
  end
end
