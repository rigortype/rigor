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
      expect(File.read(marker).strip).to eq(described_class.schema_marker_value)
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
        .to eq(described_class.schema_marker_value)
    end
  end

  describe "format-version marker (ADR-54)" do
    it "clears the root left by a pre-compression Rigor (old marker without the format suffix)" do
      # A pre-WD2 cache: marker carries only the descriptor schema
      # ("3"), and its entries are unreadable v1 bytes that no run
      # would otherwise ever reclaim (they sit below the eviction cap).
      FileUtils.mkdir_p(File.join(cache_root, "p", "ab"))
      stale_entry = File.join(cache_root, "p", "ab", "cdef.entry")
      File.binwrite(stale_entry, "RIGOR\x00\x01stale-v1-bytes#{"\x00" * 32}")
      File.write(File.join(cache_root, "schema_version.txt"),
                 "#{Rigor::Cache::Descriptor::SCHEMA_VERSION}\n")

      described_class.new(root: cache_root)
                     .fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) { :fresh }

      expect(File.exist?(stale_entry)).to be(false)
      expect(File.read(File.join(cache_root, "schema_version.txt")).strip)
        .to eq(described_class.schema_marker_value)
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

    it "stores raw serialised bytes (no Marshal wrapping) under the deflate envelope" do
      json_serialize = ->(value) { JSON.generate(value) }
      seen_bytes = nil
      json_deserialize = lambda { |bytes|
        seen_bytes = bytes.dup
        JSON.parse(bytes)
      }
      store.fetch_or_compute(
        producer_id: "demo", params: {}, descriptor: descriptor,
        serialize: json_serialize, deserialize: json_deserialize
      ) { { "name" => "Alice", "age" => 30 } }

      key = descriptor.cache_key_for(producer_id: "demo", params: {})
      entry_path = File.join(cache_root, "demo", key[0, 2], "#{key[2..]}.entry")
      bytes = File.binread(entry_path)
      # ADR-54 WD2 — the value payload is zlib-deflated on disk, so
      # the serialiser output no longer appears verbatim in the file...
      expect(bytes).not_to include('{"name":"Alice","age":30}')

      # ...but the deserialiser receives EXACTLY the serialiser's
      # bytes back (no Marshal wrapping; compression is transparent
      # at the contract layer). A fresh Store forces the disk read.
      fresh = described_class.new(root: cache_root)
      result = fresh.fetch_or_compute(
        producer_id: "demo", params: {}, descriptor: descriptor,
        serialize: json_serialize, deserialize: json_deserialize
      ) { :should_not_run }
      expect(seen_bytes).to eq('{"name":"Alice","age":30}')
      expect(result).to eq({ "name" => "Alice", "age" => 30 })
    end

    it "treats a pre-compression (format v1) entry as a cache miss" do
      store.fetch_or_compute(producer_id: "demo", params: {}, descriptor: descriptor) { :v2_value }
      key = descriptor.cache_key_for(producer_id: "demo", params: {})
      entry_path = File.join(cache_root, "demo", key[0, 2], "#{key[2..]}.entry")
      bytes = File.binread(entry_path).dup
      bytes[6] = "\x01".b # rewind the format-version byte to v1

      File.binwrite(entry_path, bytes)

      called = 0
      result = described_class.new(root: cache_root).fetch_or_compute(
        producer_id: "demo", params: {}, descriptor: descriptor
      ) do
        called += 1
        :recomputed
      end
      expect(called).to eq(1)
      expect(result).to eq(:recomputed)
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

  describe "#fetch_or_validate (ADR-45 record-and-validate)" do
    def fresh_descriptor(path, value)
      Rigor::Cache::Descriptor.new(
        files: [Rigor::Cache::Descriptor::FileEntry.new(path: path, comparator: :digest,
                                                        value: Digest::SHA256.hexdigest(value))]
      )
    end

    it "misses, runs the block, writes, and returns the produced value" do
      called = 0
      result = store.fetch_or_validate(producer_id: "p", key_descriptor: descriptor, params: { x: 1 }) do
        called += 1
        [{ v: 42 }, Rigor::Cache::Descriptor.new]
      end

      expect(called).to eq(1)
      expect(result).to eq(v: 42)
      key = descriptor.cache_key_for(producer_id: "p", params: { x: 1 })
      expect(File.exist?(File.join(cache_root, "p", key[0, 2], "#{key[2..]}.entry"))).to be(true)
    end

    it "serves a fresh entry as a hit without re-running the block, across a fresh Store" do
      file = File.join(tmpdir, "dep.txt")
      File.write(file, "v1")
      produce = lambda do
        content = File.read(file)
        [content, fresh_descriptor(file, content)]
      end

      first = described_class.new(root: cache_root).fetch_or_validate(
        producer_id: "p", key_descriptor: Rigor::Cache::Descriptor.new, params: {}, &produce
      )
      expect(first).to eq("v1")

      called = 0
      second_store = described_class.new(root: cache_root)
      second = second_store.fetch_or_validate(
        producer_id: "p", key_descriptor: Rigor::Cache::Descriptor.new, params: {}
      ) do
        called += 1
        ["should-not-run", Rigor::Cache::Descriptor.new]
      end
      expect(called).to eq(0)
      expect(second).to eq("v1")
      expect(second_store.stats).to include(hits: 1, misses: 0)
    end

    it "recomputes when the stored dependency_descriptor is stale (dependency file changed)" do
      file = File.join(tmpdir, "dep.txt")
      File.write(file, "v1")

      run = lambda do |s|
        s.fetch_or_validate(producer_id: "p", key_descriptor: Rigor::Cache::Descriptor.new, params: {}) do
          content = File.read(file)
          [content, fresh_descriptor(file, content)]
        end
      end

      expect(run.call(described_class.new(root: cache_root))).to eq("v1")

      File.write(file, "v2")
      called = 0
      result = described_class.new(root: cache_root).fetch_or_validate(
        producer_id: "p", key_descriptor: Rigor::Cache::Descriptor.new, params: {}
      ) do
        called += 1
        content = File.read(file)
        [content, fresh_descriptor(file, content)]
      end
      expect(called).to eq(1)
      expect(result).to eq("v2")
    end

    it "increments misses (and writes on success) on every miss, hits on a fresh re-read" do
      3.times do |i|
        described_class.new(root: cache_root).fetch_or_validate(
          producer_id: "demo", key_descriptor: descriptor, params: { i: i }
        ) { [i, Rigor::Cache::Descriptor.new] }
      end
      hit_store = described_class.new(root: cache_root)
      2.times do
        hit_store.fetch_or_validate(
          producer_id: "demo", key_descriptor: descriptor, params: { i: 0 }
        ) { [:unused, Rigor::Cache::Descriptor.new] }
      end

      stats = hit_store.stats
      expect(stats).to include(misses: 0, writes: 0, hits: 2)
    end

    it "treats a missing block as [nil, Descriptor.new] and does not raise" do
      result = store.fetch_or_validate(producer_id: "p", key_descriptor: descriptor, params: {})
      expect(result).to be_nil
    end

    it "does not write to disk and does not raise when read_only" do
      ro = described_class.new(root: cache_root, read_only: true)
      called = 0
      result = ro.fetch_or_validate(producer_id: "p", key_descriptor: descriptor, params: {}) do
        called += 1
        [:v, Rigor::Cache::Descriptor.new]
      end

      expect(called).to eq(1)
      expect(result).to eq(:v)
      key = descriptor.cache_key_for(producer_id: "p", params: {})
      expect(File.exist?(File.join(cache_root, "p", key[0, 2], "#{key[2..]}.entry"))).to be(false)
      expect(ro.stats).to include(writes: 0, misses: 1)
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
      expect(inv[:schema_version]).to eq(described_class.schema_marker_value)
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

  describe "atomic write (#write_entry / #atomically_replace)" do
    it "round-trips the exact written value and leaves no .tmp file behind" do
      store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) { "the-value" }
      key = descriptor.cache_key_for(producer_id: "p", params: {})
      entry_path = File.join(cache_root, "p", key[0, 2], "#{key[2..]}.entry")

      expect(File.exist?(entry_path)).to be(true)
      expect(Dir.glob("#{entry_path}.tmp.*")).to be_empty

      fresh = described_class.new(root: cache_root)
      result = fresh.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) { :should_not_run }
      expect(result).to eq("the-value")
    end

    it "derives the temp filename's random suffix from SecureRandom.hex(4) (16 hex chars)" do
      allow(SecureRandom).to receive(:hex).and_call_original
      store.fetch_or_compute(producer_id: "p", params: {}, descriptor: descriptor) { :v }
      expect(SecureRandom).to have_received(:hex).with(4)
    end

    it "does not collide across concurrent writers targeting the same entry (unique temp names)" do
      key = descriptor.cache_key_for(producer_id: "p", params: {})
      entry_path = File.join(cache_root, "p", key[0, 2], "#{key[2..]}.entry")

      threads = Array.new(16) do |i|
        Thread.new do
          described_class.new(root: cache_root).fetch_or_compute(
            producer_id: "p", params: {}, descriptor: descriptor
          ) { "value-#{i}" }
        end
      end
      threads.each(&:join)

      # Every writer raced for the SAME entry; the last rename wins but the
      # entry must be intact (one of the written values) and no temp file
      # from any writer is left behind — collisions there would clobber a
      # sibling writer's in-flight temp file.
      expect(Dir.glob("#{entry_path}.tmp.*")).to be_empty
      final = described_class.new(root: cache_root).fetch_or_compute(
        producer_id: "p", params: {}, descriptor: descriptor
      ) { :should_not_run }
      expect(final).to match(/\Avalue-\d+\z/)
    end
  end

  describe "#write_varint (private LEB128 encoder)" do
    it "raises ArgumentError for a negative value" do
      expect do
        store.send(:write_varint, +"".b, -1)
      end.to raise_error(ArgumentError, "varint must be non-negative")
    end
  end

  describe "#evict! (ADR-6 LRU eviction)" do
    def write_entry(store, producer_id, key, value)
      store.fetch_or_compute(
        producer_id: producer_id, params: { k: key },
        descriptor: Rigor::Cache::Descriptor.new
      ) { value }
    end

    it "is a no-op when max_bytes is not configured" do
      store_no_cap = described_class.new(root: cache_root)
      write_entry(store_no_cap, "evict.test", "a", "x" * 1000)
      expect { store_no_cap.evict! }.not_to raise_error
      expect(Dir.glob(File.join(cache_root, "**", "*.entry")).size).to eq(1)
    end

    it "removes the oldest entry when total size exceeds the cap" do
      capped = described_class.new(root: cache_root, max_bytes: 1)
      write_entry(capped, "evict.test", "a", "content_a")
      write_entry(capped, "evict.test", "b", "content_b")

      entries_before = Dir.glob(File.join(cache_root, "**", "*.entry"))
      expect(entries_before.size).to eq(2)

      capped.evict!

      entries_after = Dir.glob(File.join(cache_root, "**", "*.entry"))
      expect(entries_after.size).to be < 2
    end

    it "keeps entries whose total is under the cap" do
      # Cap large enough to hold both entries.
      large_cap = described_class.new(root: cache_root, max_bytes: 10 * 1024 * 1024)
      write_entry(large_cap, "evict.test", "a", "content_a")
      write_entry(large_cap, "evict.test", "b", "content_b")

      large_cap.evict!

      expect(Dir.glob(File.join(cache_root, "**", "*.entry")).size).to eq(2)
    end

    it "is a no-op on a read-only store (never touches disk)" do
      # Write entries with a writable store first.
      write_entry(store, "evict.test", "a", "content_a")

      ro = described_class.new(root: cache_root, read_only: true, max_bytes: 1)
      ro.evict!

      expect(Dir.glob(File.join(cache_root, "**", "*.entry")).size).to eq(1)
    end

    it "updates mtime on disk-read hits (the cross-process LRU signal)" do
      capped = described_class.new(root: cache_root, max_bytes: 10 * 1024 * 1024)
      write_entry(capped, "evict.test", "a", "content_a")

      path = Dir.glob(File.join(cache_root, "**", "*.entry")).first
      old_mtime = File.mtime(path)

      # Wait a small amount so mtime can differ, then read via a fresh store
      # (no in-process memo).
      sleep(0.05)
      fresh = described_class.new(root: cache_root, max_bytes: 10 * 1024 * 1024)
      fresh.fetch_or_compute(
        producer_id: "evict.test", params: { k: "a" },
        descriptor: Rigor::Cache::Descriptor.new
      ) { raise "should not be called" }

      expect(File.mtime(path)).to be > old_mtime
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
