# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Rigor::Cache::Store do
  let(:tmpdir) { Dir.mktmpdir("rigor-cache-store-spec-") }
  let(:cache_root) { File.join(tmpdir, ".rigor", "cache") }
  let(:store) { described_class.new(root: cache_root) }
  let(:descriptor) { Rigor::Cache::Descriptor.new }

  after { FileUtils.rm_rf(tmpdir) }

  describe "#fetch_or_compute" do
    it "runs the block on cache miss and returns its value" do
      called = 0
      result = store.fetch_or_compute(producer_id: "test.producer", params: { x: 1 }, descriptor: descriptor) do
        called += 1
        { value: 42 }
      end
      expect(called).to eq(1)
      expect(result).to eq(value: 42)
    end

    it "skips the block on cache hit and returns the stored value" do
      store.fetch_or_compute(producer_id: "test.producer", params: { x: 1 }, descriptor: descriptor) do
        { value: 42 }
      end

      called = 0
      result = store.fetch_or_compute(producer_id: "test.producer", params: { x: 1 }, descriptor: descriptor) do
        called += 1
        { value: 0 }
      end
      expect(called).to eq(0)
      expect(result).to eq(value: 42)
    end

    it "treats different params as different cache entries" do
      a = store.fetch_or_compute(producer_id: "p", params: { x: 1 }, descriptor: descriptor) { :a }
      b = store.fetch_or_compute(producer_id: "p", params: { x: 2 }, descriptor: descriptor) { :b }
      expect(a).to eq(:a)
      expect(b).to eq(:b)
    end

    it "treats different descriptors as different cache entries" do
      d1 = Rigor::Cache::Descriptor.new
      d2 = Rigor::Cache::Descriptor.new(
        files: [Rigor::Cache::Descriptor::FileEntry.new(path: "a.rb", comparator: :digest, value: "abc")]
      )
      a = store.fetch_or_compute(producer_id: "p", params: {}, descriptor: d1) { :a }
      b = store.fetch_or_compute(producer_id: "p", params: {}, descriptor: d2) { :b }
      expect(a).to eq(:a)
      expect(b).to eq(:b)
    end

    it "treats different producer_ids as different cache entries" do
      a = store.fetch_or_compute(producer_id: "p1", params: {}, descriptor: descriptor) { :a }
      b = store.fetch_or_compute(producer_id: "p2", params: {}, descriptor: descriptor) { :b }
      expect(a).to eq(:a)
      expect(b).to eq(:b)
    end

    it "round-trips Marshal-serialisable values" do
      payload = { strings: %w[a b], symbols: %i[x y], nested: { n: 1 } }
      store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) { payload }
      result = store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) { :should_not_run }
      expect(result).to eq(payload)
    end

    it "rejects an invalid producer_id (only [a-z0-9._-] allowed)" do
      expect do
        store.fetch_or_compute(producer_id: "Bad/Producer", params: {}, descriptor: descriptor) { :v }
      end.to raise_error(ArgumentError, /producer_id/)
    end
  end

  describe "on-disk layout" do
    it "writes a sharded path .rigor/cache/<producer-id>/<2-prefix>/<62-suffix>.entry" do
      key = descriptor.cache_key_for(producer_id: "p", params: { x: 1 })
      store.fetch_or_compute(producer_id: "p", params: { x: 1 }, descriptor: descriptor) { :v }

      expected = File.join(cache_root, "p", key[0, 2], "#{key[2..]}.entry")
      expect(File.exist?(expected)).to be true
    end

    it "writes a schema_version.txt marker at the cache root" do
      store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) { :v }
      marker = File.join(cache_root, "schema_version.txt")
      expect(File.read(marker).strip).to eq(Rigor::Cache::Descriptor::SCHEMA_VERSION.to_s)
    end

    it "leaves no .tmp files behind on a successful write" do
      store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) { :v }
      stragglers = Dir.glob(File.join(cache_root, "**", "*.tmp.*"))
      expect(stragglers).to be_empty
    end
  end

  describe "schema-version mismatch" do
    it "drops the cache directory when the marker disagrees with SCHEMA_VERSION" do
      store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) { :first }
      File.write(File.join(cache_root, "schema_version.txt"), "999")

      # The disk-level schema-mismatch recovery applies on
      # the disk-read path. A fresh `Store` (process restart
      # / new CLI invocation) is the scenario that triggers
      # it; the same-instance in-memory memo would skip the
      # disk read entirely.
      fresh_store = described_class.new(root: cache_root)
      called = 0
      result = fresh_store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) do
        called += 1
        :second
      end
      expect(called).to eq(1)
      expect(result).to eq(:second)
      expect(File.read(File.join(cache_root, "schema_version.txt")).strip)
        .to eq(Rigor::Cache::Descriptor::SCHEMA_VERSION.to_s)
    end
  end

  describe "custom serialize: / deserialize: (v0.0.9 C1)" do
    let(:upcase_serialize) { :upcase.to_proc }
    let(:downcase_deserialize) { :downcase.to_proc }

    it "round-trips through the supplied callables" do
      store.fetch_or_compute(
        producer_id: "demo", params: {}, descriptor: descriptor,
        serialize: upcase_serialize, deserialize: downcase_deserialize
      ) { "hello" }

      result = store.fetch_or_compute(
        producer_id: "demo", params: {}, descriptor: descriptor,
        serialize: upcase_serialize, deserialize: downcase_deserialize
      ) { :should_not_run }

      # The value was UPCASE-ed on write, then downcase-d on read.
      expect(result).to eq("hello")
    end

    it "writes raw serialised bytes (no Marshal wrapping)" do
      json_serialize = ->(value) { JSON.generate(value) }
      json_deserialize = ->(bytes) { JSON.parse(bytes) }
      store.fetch_or_compute(
        producer_id: "demo", params: {}, descriptor: descriptor,
        serialize: json_serialize, deserialize: json_deserialize
      ) { { "name" => "Alice", "age" => 30 } }

      key = descriptor.cache_key_for(producer_id: "demo", params: {})
      entry_path = File.join(cache_root, "demo", key[0, 2], "#{key[2..]}.entry")
      bytes = File.binread(entry_path)
      # Custom serialiser bytes must appear verbatim somewhere in the entry body.
      expect(bytes).to include('{"name":"Alice","age":30}')
    end

    it "raises TypeError when serialize returns a non-String" do
      bad = ->(_) { 42 }
      expect do
        store.fetch_or_compute(producer_id: "demo", params: {}, descriptor: descriptor, serialize: bad) { "x" }
      end.to raise_error(TypeError, /serialize must return a String/)
    end

    it "treats a deserialize raise as a cache miss" do
      identity = ->(v) { v }
      raising = ->(_) { raise "boom" }
      store.fetch_or_compute(
        producer_id: "demo", params: {}, descriptor: descriptor,
        serialize: identity, deserialize: identity
      ) { "first" }
      # `Store#fetch_or_compute` memoises the produced value
      # in-process; the disk-read deserialise path is exercised
      # by a fresh `Store` ("process restart" scenario).
      fresh_store = described_class.new(root: cache_root)
      result = fresh_store.fetch_or_compute(
        producer_id: "demo", params: {}, descriptor: descriptor,
        serialize: identity, deserialize: raising
      ) { "second" }
      expect(result).to eq("second")
    end

    it "keeps the default Marshal path unchanged when serialize/deserialize are omitted" do
      result = store.fetch_or_compute(producer_id: "demo", params: {}, descriptor: descriptor) do
        { complex: [1, "two", :three] }
      end
      expect(result).to eq(complex: [1, "two", :three])

      hit = store.fetch_or_compute(producer_id: "demo", params: {}, descriptor: descriptor) { :should_not_run }
      expect(hit).to eq(complex: [1, "two", :three])
    end
  end

  describe "#stats (v0.0.9 group A slice 3)" do
    it "starts at zero hits / misses / writes" do
      expect(store.stats).to include(hits: 0, misses: 0, writes: 0)
      expect(store.stats.fetch(:by_producer)).to be_empty
    end

    it "increments misses and writes on a cache miss, hits on subsequent reads" do
      3.times do |i|
        store.fetch_or_compute(producer_id: "demo", params: { i: i }, descriptor: descriptor) { i }
      end
      store.fetch_or_compute(producer_id: "demo", params: { i: 0 }, descriptor: descriptor) { :unused }
      store.fetch_or_compute(producer_id: "demo", params: { i: 0 }, descriptor: descriptor) { :unused }

      stats = store.stats
      expect(stats).to include(misses: 3, writes: 3, hits: 2)
      expect(stats.fetch(:by_producer)).to include("demo" => { hits: 2, misses: 3, writes: 3 })
    end

    it "tracks counters separately per producer" do
      store.fetch_or_compute(producer_id: "alpha", params: {}, descriptor: descriptor) { :a }
      store.fetch_or_compute(producer_id: "beta", params: {}, descriptor: descriptor) { :b }
      store.fetch_or_compute(producer_id: "alpha", params: {}, descriptor: descriptor) { :unused }

      by_producer = store.stats.fetch(:by_producer)
      expect(by_producer.fetch("alpha")).to eq(hits: 1, misses: 1, writes: 1)
      expect(by_producer.fetch("beta")).to eq(hits: 0, misses: 1, writes: 1)
    end

    it "returns a frozen snapshot so callers cannot mutate the live counters" do
      store.fetch_or_compute(producer_id: "demo", params: {}, descriptor: descriptor) { :v }
      snapshot = store.stats
      expect(snapshot).to be_frozen
      expect(snapshot.fetch(:by_producer)).to be_frozen
      expect(snapshot.fetch(:by_producer).fetch("demo")).to be_frozen
    end
  end

  describe ".disk_inventory" do
    it "returns nil schema_version and an empty producer list when the root does not exist" do
      inv = described_class.disk_inventory(root: cache_root)
      expect(inv[:schema_version]).to be_nil
      expect(inv[:producers]).to eq([])
      expect(inv[:total_entries]).to eq(0)
    end

    it "reports per-producer entry counts after writes" do
      store.fetch_or_compute(producer_id: "alpha", params: { x: 1 }, descriptor: descriptor) { :a }
      store.fetch_or_compute(producer_id: "alpha", params: { x: 2 }, descriptor: descriptor) { :b }
      store.fetch_or_compute(producer_id: "beta", params: {}, descriptor: descriptor) { :c }

      inv = described_class.disk_inventory(root: cache_root)
      expect(inv[:schema_version]).to eq(Rigor::Cache::Descriptor::SCHEMA_VERSION.to_s)
      expect(inv[:total_entries]).to eq(3)
      expect(inv[:total_bytes]).to be > 0
      ids = inv[:producers].map { |p| p[:id] }
      expect(ids).to contain_exactly("alpha", "beta")
      alpha = inv[:producers].find { |p| p[:id] == "alpha" }
      expect(alpha[:entries]).to eq(2)
      expect(alpha[:bytes]).to be > 0
    end
  end

  describe "corruption tolerance" do
    let(:key) { descriptor.cache_key_for(producer_id: "p", params: {}) }
    let(:entry_path) { File.join(cache_root, "p", key[0, 2], "#{key[2..]}.entry") }

    before do
      store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) { :first }
    end

    # The corruption-tolerance cases simulate the disk being
    # mutated externally (e.g. by a buggy editor or a crash
    # mid-write). The fault-tolerance guarantee is "a fresh
    # process reading the corrupt entry treats it as a miss";
    # an in-process `Store` that already produced the value
    # legitimately keeps it in memory and never touches disk.
    # Each test re-creates the `Store` post-corruption to
    # exercise the fault-tolerance path.
    def fresh_store_after_corruption
      described_class.new(root: cache_root)
    end

    it "treats a truncated entry file as a cache miss" do
      bytes = File.binread(entry_path)
      File.binwrite(entry_path, bytes[0, bytes.bytesize - 5])

      called = 0
      result = fresh_store_after_corruption.fetch_or_compute(
        producer_id: "p", params: {}, descriptor: descriptor
      ) do
        called += 1
        :second
      end
      expect(called).to eq(1)
      expect(result).to eq(:second)
    end

    it "treats a bad magic header as a cache miss and overwrites" do
      File.binwrite(entry_path, "GARBAGE\x00\x01#{"\x00" * 64}")

      called = 0
      result = fresh_store_after_corruption.fetch_or_compute(
        producer_id: "p", params: {}, descriptor: descriptor
      ) do
        called += 1
        :second
      end
      expect(called).to eq(1)
      expect(result).to eq(:second)
    end

    it "treats a bad SHA-256 trailer as a cache miss" do
      bytes = File.binread(entry_path).dup
      bytes[-1] = bytes[-1] == "\x00".b ? "\x01".b : "\x00".b
      File.binwrite(entry_path, bytes)

      called = 0
      result = fresh_store_after_corruption.fetch_or_compute(
        producer_id: "p", params: {}, descriptor: descriptor
      ) do
        called += 1
        :second
      end
      expect(called).to eq(1)
      expect(result).to eq(:second)
    end
  end

  describe "read_only: true (editor mode — slice 3)" do
    let(:ro_store) { described_class.new(root: cache_root, read_only: true) }

    it "exposes the flag via #read_only?" do
      expect(ro_store.read_only?).to be(true)
      expect(store.read_only?).to be(false)
    end

    it "runs the producer block on miss and returns its value without writing to disk" do
      called = 0
      result = ro_store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) do
        called += 1
        :produced
      end

      expect(called).to eq(1)
      expect(result).to eq(:produced)
      key = descriptor.cache_key_for(producer_id: "p", params: {})
      expect(File.exist?(File.join(cache_root, "p", key[0, 2], "#{key[2..]}.entry"))).to be(false)
    end

    it "does not write the schema_version.txt marker even on a fresh root" do
      ro_store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) { :v }

      expect(File.exist?(File.join(cache_root, "schema_version.txt"))).to be(false)
    end

    it "still serves hits from disk when an existing entry is present" do
      # Warm the cache with a write-enabled store.
      store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) { :warm }

      called = 0
      result = ro_store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) do
        called += 1
        :should_not_run
      end

      expect(called).to eq(0)
      expect(result).to eq(:warm)
    end

    it "leaves the writes counter at zero (misses still recorded so callers can detect cold runs)" do
      ro_store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) { :v }
      ro_store.fetch_or_compute(producer_id: "p", params: { other: 1 }, descriptor: descriptor) { :w }

      stats = ro_store.stats
      expect(stats[:writes]).to eq(0)
      expect(stats[:misses]).to be > 0
    end

    it "memoises within the same instance so repeated lookups skip the producer" do
      called = 0
      2.times do
        ro_store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) do
          called += 1
          :v
        end
      end

      expect(called).to eq(1)
    end
  end
end
