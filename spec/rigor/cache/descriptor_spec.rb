# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe Rigor::Cache::Descriptor do
  describe "construction" do
    it "defaults every slot to an empty array" do
      d = described_class.new
      expect(d.files).to eq([])
      expect(d.gems).to eq([])
      expect(d.plugins).to eq([])
      expect(d.configs).to eq([])
    end

    it "accepts entries via keyword arguments" do
      d = described_class.new(
        files: [described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "abc")],
        gems: [described_class::GemEntry.new(name: "rbs", requirement: "*", locked: "4.0.0")]
      )
      expect(d.files.size).to eq(1)
      expect(d.gems.size).to eq(1)
    end

    it "freezes its slots so callers cannot mutate after construction" do
      d = described_class.new(files: [described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "abc")])
      expect(d.files).to be_frozen
      expect { d.files << :nope }.to raise_error(FrozenError)
    end
  end

  describe "FileEntry" do
    it "rejects an unknown comparator" do
      expect do
        described_class::FileEntry.new(path: "a.rb", comparator: :checksum, value: "x")
      end.to raise_error(ArgumentError, /comparator/)
    end

    it "accepts :digest, :mtime, :exists" do
      %i[digest mtime exists].each do |c|
        entry = described_class::FileEntry.new(path: "a.rb", comparator: c, value: "x")
        expect(entry.comparator).to eq(c)
      end
    end
  end

  describe "PluginEntry" do
    it "stores id, version, and config_hash as given" do
      entry = described_class::PluginEntry.new(id: "rigor-rspec", version: "1.2.3", config_hash: "cfg-hash")
      expect(entry.id).to eq("rigor-rspec")
      expect(entry.version).to eq("1.2.3")
      expect(entry.config_hash).to eq("cfg-hash")
    end

    it "freezes after construction" do
      entry = described_class::PluginEntry.new(id: "rigor-rspec", version: "1.2.3")
      expect(entry).to be_frozen
    end

    it "#to_h renders the exact id/version/config_hash triple" do
      entry = described_class::PluginEntry.new(id: "rigor-rspec", version: "1.2.3", config_hash: "cfg-hash")
      expect(entry.to_h).to eq({ "id" => "rigor-rspec", "version" => "1.2.3", "config_hash" => "cfg-hash" })
    end
  end

  describe "ConfigEntry" do
    it "#to_h renders the exact key/value_hash pair" do
      entry = described_class::ConfigEntry.new(key: "url:https://x", value_hash: "deadbeef")
      expect(entry.to_h).to eq({ "key" => "url:https://x", "value_hash" => "deadbeef" })
    end
  end

  describe "DependencyEntry" do
    it "rejects an unknown mode" do
      expect do
        described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :strict)
      end.to raise_error(ArgumentError, /mode/)
    end

    it "accepts the three ADR-10 modes" do
      %i[disabled when_missing full].each do |m|
        entry = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: m)
        expect(entry.mode).to eq(m)
      end
    end

    it "is value-equal across construction sites" do
      a = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      b = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "freezes after construction" do
      entry = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      expect(entry).to be_frozen
    end
  end

  describe ".compose" do
    let(:file_a_digest) { described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "abc") }
    let(:file_a_mtime) do
      described_class::FileEntry.new(path: "a.rb", comparator: :mtime, value: "2026-05-05T00:00:00Z")
    end
    let(:file_b_digest) { described_class::FileEntry.new(path: "b.rb", comparator: :digest, value: "def") }
    let(:rbs_pinned_old) { described_class::GemEntry.new(name: "rbs", requirement: ">= 4", locked: "4.0.0") }
    let(:rbs_pinned_new) { described_class::GemEntry.new(name: "rbs", requirement: ">= 4", locked: "4.1.0") }
    let(:prism_gem) { described_class::GemEntry.new(name: "prism", requirement: "*", locked: "1.0.0") }

    it "unions disjoint slots by key" do
      a = described_class.new(files: [file_a_digest])
      b = described_class.new(files: [file_b_digest])
      composed = described_class.compose(a, b)
      expect(composed.files.map(&:path)).to contain_exactly("a.rb", "b.rb")
    end

    it "unions matching entries idempotently" do
      a = described_class.new(files: [file_a_digest], gems: [rbs_pinned_old])
      b = described_class.new(files: [file_a_digest], gems: [rbs_pinned_old])
      composed = described_class.compose(a, b)
      expect(composed.files.size).to eq(1)
      expect(composed.gems.size).to eq(1)
    end

    it "prefers the stricter comparator on file conflicts (digest > mtime > exists)" do
      a = described_class.new(files: [file_a_mtime])
      b = described_class.new(files: [file_a_digest])
      composed = described_class.compose(a, b)
      expect(composed.files.first.comparator).to eq(:digest)
    end

    it "raises a Conflict on disagreeing values under the stricter comparator" do
      other = described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "different")
      a = described_class.new(files: [file_a_digest])
      b = described_class.new(files: [other])
      expect { described_class.compose(a, b) }.to raise_error(described_class::Conflict)
    end

    it "raises a Conflict on disagreeing gem `locked` versions" do
      a = described_class.new(gems: [rbs_pinned_old])
      b = described_class.new(gems: [rbs_pinned_new])
      expect { described_class.compose(a, b) }.to raise_error(described_class::Conflict)
    end

    it "unions disjoint gems by name" do
      a = described_class.new(gems: [rbs_pinned_old])
      b = described_class.new(gems: [prism_gem])
      composed = described_class.compose(a, b)
      expect(composed.gems.map(&:name)).to contain_exactly("rbs", "prism")
    end

    it "unions disjoint dependency entries by gem_name" do
      rack = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      faraday = described_class::DependencyEntry.new(gem_name: "faraday", gem_version: "2.7.0", mode: :when_missing)
      composed = described_class.compose(
        described_class.new(dependencies: [rack]),
        described_class.new(dependencies: [faraday])
      )
      expect(composed.dependencies.map(&:gem_name)).to contain_exactly("rack", "faraday")
    end

    it "unions matching dependency entries idempotently" do
      rack = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      composed = described_class.compose(
        described_class.new(dependencies: [rack]),
        described_class.new(dependencies: [rack])
      )
      expect(composed.dependencies.size).to eq(1)
    end

    it "raises a Conflict when two dependency entries disagree on gem_version" do
      old = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      new_ver = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.1.0", mode: :when_missing)
      a = described_class.new(dependencies: [old])
      b = described_class.new(dependencies: [new_ver])
      expect { described_class.compose(a, b) }.to raise_error(described_class::Conflict)
    end

    it "raises a Conflict when two dependency entries disagree on mode" do
      lenient = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      strict = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :full)
      expect do
        described_class.compose(
          described_class.new(dependencies: [lenient]),
          described_class.new(dependencies: [strict])
        )
      end.to raise_error(described_class::Conflict)
    end
  end

  describe ".compose with no descriptors" do
    it "returns a fresh empty descriptor" do
      composed = described_class.compose
      expect(composed).to be_a(described_class)
      expect(composed.files).to eq([])
      expect(composed.gems).to eq([])
      expect(composed.plugins).to eq([])
      expect(composed.configs).to eq([])
      expect(composed.dependencies).to eq([])
      expect(composed.globs).to eq([])
    end
  end

  describe "per-gem-version invalidation (ADR-10 slice 3)" do
    let(:rack_old) { described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing) }
    let(:rack_new) { described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.1.0", mode: :when_missing) }
    let(:rack_full) { described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :full) }
    let(:faraday) do
      described_class::DependencyEntry.new(gem_name: "faraday", gem_version: "2.7.0", mode: :when_missing)
    end

    it "produces a different cache key when the gem_version bumps" do
      a = described_class.new(dependencies: [rack_old])
      b = described_class.new(dependencies: [rack_new])
      key_a = a.cache_key_for(producer_id: "p", params: {})
      key_b = b.cache_key_for(producer_id: "p", params: {})
      expect(key_a).not_to eq(key_b)
    end

    it "produces a different cache key when the mode changes" do
      a = described_class.new(dependencies: [rack_old])
      b = described_class.new(dependencies: [rack_full])
      key_a = a.cache_key_for(producer_id: "p", params: {})
      key_b = b.cache_key_for(producer_id: "p", params: {})
      expect(key_a).not_to eq(key_b)
    end

    it "leaves other gems' slices stable when one gem bumps" do
      before = described_class.new(dependencies: [rack_old, faraday])
      after = described_class.new(dependencies: [rack_new, faraday])
      # The invariant that matters: the descriptor for a producer
      # keyed only on `faraday` does not change when `rack`
      # bumps. Slice 3 lands the *primitive* — composing a
      # producer's per-gem descriptor with the index's
      # contribution is the consumer's job (slice 4+).
      faraday_only_before = described_class.new(dependencies: [faraday])
      faraday_only_after = described_class.new(dependencies: [faraday])
      expect(faraday_only_before.cache_key_for(producer_id: "p", params: {}))
        .to eq(faraday_only_after.cache_key_for(producer_id: "p", params: {}))
      # And the multi-gem composite does change, as expected.
      expect(before.cache_key_for(producer_id: "p", params: {}))
        .not_to eq(after.cache_key_for(producer_id: "p", params: {}))
    end
  end

  describe "#to_canonical_bytes" do
    it "serialises to canonical JSON with sorted keys and slots" do
      d = described_class.new(
        gems: [described_class::GemEntry.new(name: "rbs", requirement: ">= 4", locked: "4.0.0")],
        files: [described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "abc")]
      )
      bytes = d.to_canonical_bytes
      # Slots must appear in lexicographic order regardless of construction order.
      expect(bytes).to include('"configs":[]')
      expect(bytes).to include('"dependencies":[]')
      expect(bytes).to include('"files":[')
      expect(bytes).to include('"gems":[')
      expect(bytes).to include('"globs":[]')
      expect(bytes).to include('"plugins":[]')
      slot_order = %w[configs dependencies files gems globs plugins].map { |s| bytes.index(%("#{s}")) }
      expect(slot_order).to eq(slot_order.sort)
    end

    it "produces identical bytes for descriptors built in different orders" do
      a = described_class.new(
        files: [
          described_class::FileEntry.new(path: "b.rb", comparator: :digest, value: "B"),
          described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "A")
        ]
      )
      b = described_class.new(
        files: [
          described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "A"),
          described_class::FileEntry.new(path: "b.rb", comparator: :digest, value: "B")
        ]
      )
      expect(a.to_canonical_bytes).to eq(b.to_canonical_bytes)
    end

    it "sorts configs by key regardless of construction order" do
      d = described_class.new(
        configs: [
          described_class::ConfigEntry.new(key: "z-key", value_hash: "z"),
          described_class::ConfigEntry.new(key: "a-key", value_hash: "a")
        ]
      )
      keys = d.to_canonical_hash.fetch("configs").map { |h| h.fetch("key") }
      expect(keys).to eq(%w[a-key z-key])
    end

    it "sorts dependencies by gem_name regardless of construction order" do
      d = described_class.new(
        dependencies: [
          described_class::DependencyEntry.new(gem_name: "zeitwerk", gem_version: "1.0.0", mode: :when_missing),
          described_class::DependencyEntry.new(gem_name: "faraday", gem_version: "2.0.0", mode: :when_missing)
        ]
      )
      names = d.to_canonical_hash.fetch("dependencies").map { |h| h.fetch("gem_name") }
      expect(names).to eq(%w[faraday zeitwerk])
    end

    it "sorts plugins by id regardless of construction order" do
      d = described_class.new(
        plugins: [
          described_class::PluginEntry.new(id: "z-plugin", version: "1.0.0"),
          described_class::PluginEntry.new(id: "a-plugin", version: "1.0.0")
        ]
      )
      ids = d.to_canonical_hash.fetch("plugins").map { |h| h.fetch("id") }
      expect(ids).to eq(%w[a-plugin z-plugin])
    end

    it "sorts gems by name regardless of construction order" do
      d = described_class.new(
        gems: [
          described_class::GemEntry.new(name: "zeitwerk", requirement: "*"),
          described_class::GemEntry.new(name: "actionview", requirement: "*")
        ]
      )
      names = d.to_canonical_hash.fetch("gems").map { |h| h.fetch("name") }
      expect(names).to eq(%w[actionview zeitwerk])
    end
  end

  describe "#cache_key_for" do
    it "produces a stable hex SHA-256 over (schema_version, producer_id, params, descriptor)" do
      d = described_class.new
      key1 = d.cache_key_for(producer_id: "test.producer", params: { x: 1 })
      key2 = d.cache_key_for(producer_id: "test.producer", params: { x: 1 })
      expect(key1).to eq(key2)
      expect(key1).to match(/\A[0-9a-f]{64}\z/)
    end

    it "differs by producer_id" do
      d = described_class.new
      a = d.cache_key_for(producer_id: "a", params: {})
      b = d.cache_key_for(producer_id: "b", params: {})
      expect(a).not_to eq(b)
    end

    it "differs when the descriptor changes" do
      empty = described_class.new
      with_file = described_class.new(
        files: [described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "abc")]
      )
      expect(empty.cache_key_for(producer_id: "p", params: {}))
        .not_to eq(with_file.cache_key_for(producer_id: "p", params: {}))
    end

    it "is invariant to params hash key insertion order" do
      d = described_class.new
      a = d.cache_key_for(producer_id: "p", params: { a: 1, b: 2 })
      b = d.cache_key_for(producer_id: "p", params: { b: 2, a: 1 })
      expect(a).to eq(b)
    end

    it "differs when an array element inside params changes (canonicalize_value Array branch)" do
      d = described_class.new
      a = d.cache_key_for(producer_id: "p", params: { list: [1, 2, 3] })
      b = d.cache_key_for(producer_id: "p", params: { list: [1, 2, 4] })
      expect(a).not_to eq(b)
    end

    it "is invariant to element order within a nested hash inside an array param" do
      d = described_class.new
      a = d.cache_key_for(producer_id: "p", params: { list: [{ a: 1, b: 2 }] })
      b = d.cache_key_for(producer_id: "p", params: { list: [{ b: 2, a: 1 }] })
      expect(a).to eq(b)
    end

    it "differs when a glob entry changes (ADR-60 WD3)" do
      a = described_class.new(
        globs: [described_class::GlobEntry.new(root: "/p", pattern: "**/*.rb", value: "v1")]
      )
      b = described_class.new(
        globs: [described_class::GlobEntry.new(root: "/p", pattern: "**/*.rb", value: "v2")]
      )
      expect(a.cache_key_for(producer_id: "p", params: {}))
        .not_to eq(b.cache_key_for(producer_id: "p", params: {}))
    end
  end

  describe ".canonicalize_value" do
    it "maps each array element through canonicalize_value, preserving order" do
      result = described_class.canonicalize_value([{ b: 2, a: 1 }, :sym, "str"])
      expect(result).to eq([{ "a" => 1, "b" => 2 }, "sym", "str"])
    end
  end

  describe "#fresh? with file entries" do
    around do |example|
      Dir.mktmpdir("rigor-file-fresh-spec-") do |dir|
        @dir = dir
        example.run
      end
    end

    attr_reader :dir

    it "is fresh for a :digest entry whose file content matches, stale after edit" do
      path = File.join(dir, "a.rb")
      File.write(path, "A")
      entry = described_class::FileEntry.new(
        path: path, comparator: :digest, value: Digest::SHA256.file(path).hexdigest
      )
      d = described_class.new(files: [entry])
      expect(d.fresh?).to be(true)

      File.write(path, "A2")
      expect(d.fresh?).to be(false)
    end

    it "is fresh for a :mtime entry whose recorded value matches File.mtime.to_i, stale after touch" do
      path = File.join(dir, "a.rb")
      File.write(path, "A")
      recorded_mtime = File.mtime(path).to_i
      entry = described_class::FileEntry.new(path: path, comparator: :mtime, value: recorded_mtime.to_s)
      d = described_class.new(files: [entry])
      expect(d.fresh?).to be(true)

      File.utime(Time.now, Time.at(recorded_mtime + 1000), path)
      expect(d.fresh?).to be(false)
    end

    it "is fresh for an :exists entry recorded as present, stale once the file is removed" do
      path = File.join(dir, "a.rb")
      File.write(path, "A")
      entry = described_class::FileEntry.new(path: path, comparator: :exists, value: "true")
      d = described_class.new(files: [entry])
      expect(d.fresh?).to be(true)

      File.unlink(path)
      expect(d.fresh?).to be(false)
    end

    it "is stale for an :exists entry recorded as absent when the file is actually present" do
      path = File.join(dir, "a.rb")
      File.write(path, "A")
      entry = described_class::FileEntry.new(path: path, comparator: :exists, value: "false")
      d = described_class.new(files: [entry])
      expect(d.fresh?).to be(false)
    end
  end

  describe "GlobEntry (ADR-60 WD3)" do
    around do |example|
      Dir.mktmpdir("rigor-glob-entry-spec-") do |dir|
        @dir = dir
        example.run
      end
    end

    attr_reader :dir

    def compute
      described_class::GlobEntry.compute(root: dir, pattern: "**/*.rb")
    end

    it "digests the matched files into one stable value" do
      File.write(File.join(dir, "a.rb"), "A")
      entry = compute
      expect(entry.root).to eq(dir)
      expect(entry.pattern).to eq("**/*.rb")
      expect(entry.value).to eq(compute.value)
    end

    it "changes its value on content change, addition, AND removal" do
      File.write(File.join(dir, "a.rb"), "A")
      base = compute.value

      File.write(File.join(dir, "a.rb"), "A2")
      edited = compute.value
      expect(edited).not_to eq(base)

      File.write(File.join(dir, "b.rb"), "B")
      added = compute.value
      expect(added).not_to eq(edited)

      File.unlink(File.join(dir, "b.rb"))
      expect(compute.value).to eq(edited)
    end

    it "ignores non-matching and non-file paths" do
      File.write(File.join(dir, "a.txt"), "not matched")
      FileUtils.mkdir_p(File.join(dir, "sub.rb")) # a directory matching the glob
      empty = described_class::GlobEntry.digest_for(root: dir, pattern: "**/*.rb")
      expect(compute.value).to eq(empty)
    end

    it "is value-equal across construction sites" do
      a = described_class::GlobEntry.new(root: "/p", pattern: "*.rb", value: "v")
      b = described_class::GlobEntry.new(root: "/p", pattern: "*.rb", value: "v")
      expect(a).to eq(b)
    end
  end

  describe "#fresh? with globs (ADR-60 WD3)" do
    around do |example|
      Dir.mktmpdir("rigor-glob-fresh-spec-") do |dir|
        @dir = dir
        example.run
      end
    end

    attr_reader :dir

    def descriptor_for_current_state
      described_class.new(
        globs: [described_class::GlobEntry.compute(root: dir, pattern: "**/*.rb")]
      )
    end

    it "is fresh while the globbed files are unchanged" do
      File.write(File.join(dir, "a.rb"), "A")
      expect(descriptor_for_current_state.fresh?).to be(true)
    end

    it "goes stale on content change" do
      File.write(File.join(dir, "a.rb"), "A")
      d = descriptor_for_current_state
      File.write(File.join(dir, "a.rb"), "A2")
      expect(d.fresh?).to be(false)
    end

    it "goes stale on file addition" do
      File.write(File.join(dir, "a.rb"), "A")
      d = descriptor_for_current_state
      File.write(File.join(dir, "b.rb"), "B")
      expect(d.fresh?).to be(false)
    end

    it "goes stale on file removal" do
      File.write(File.join(dir, "a.rb"), "A")
      File.write(File.join(dir, "b.rb"), "B")
      d = descriptor_for_current_state
      File.unlink(File.join(dir, "b.rb"))
      expect(d.fresh?).to be(false)
    end

    it "still refuses non-file/glob slots" do
      d = described_class.new(
        globs: [described_class::GlobEntry.compute(root: dir, pattern: "**/*.rb")],
        configs: [described_class::ConfigEntry.new(key: "url:https://x", value_hash: "h")]
      )
      expect(d.fresh?).to be(false)
    end
  end

  describe ".compose with globs (ADR-60 WD3)" do
    it "unions glob entries per (root, pattern) slot" do
      a = described_class.new(
        globs: [described_class::GlobEntry.new(root: "/p", pattern: "*.rb", value: "v")]
      )
      b = described_class.new(
        globs: [
          described_class::GlobEntry.new(root: "/p", pattern: "*.rb", value: "v"),
          described_class::GlobEntry.new(root: "/q", pattern: "*.yml", value: "w")
        ]
      )
      composed = described_class.compose(a, b)
      expect(composed.globs.size).to eq(2)
    end

    it "raises Conflict when the same slot disagrees on the digest" do
      a = described_class.new(
        globs: [described_class::GlobEntry.new(root: "/p", pattern: "*.rb", value: "v1")]
      )
      b = described_class.new(
        globs: [described_class::GlobEntry.new(root: "/p", pattern: "*.rb", value: "v2")]
      )
      expect { described_class.compose(a, b) }.to raise_error(described_class::Conflict)
    end
  end

  describe "value semantics (#== / #eql? / #hash)" do
    let(:file_a) { described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "abc") }
    let(:file_b) { described_class::FileEntry.new(path: "b.rb", comparator: :digest, value: "def") }

    it "is == and eql? to a structurally identical descriptor" do
      a = described_class.new(files: [file_a])
      b = described_class.new(files: [file_a])
      expect(a).to eq(b)
      expect(a).to eql(b)
    end

    it "is not == to a descriptor with different canonical content" do
      expect(described_class.new(files: [file_a])).not_to eq(described_class.new(files: [file_b]))
    end

    it "hashes equal for identical descriptors and works as a Hash key" do
      a = described_class.new(files: [file_a])
      b = described_class.new(files: [file_a])
      expect(a.hash).to eq(b.hash)
      expect({ a => :value }[b]).to eq(:value)
    end
  end
end
