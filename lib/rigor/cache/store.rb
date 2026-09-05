# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "monitor"
require "securerandom"
require "zlib"

require_relative "../version"
require_relative "descriptor"

module Rigor
  module Cache
    # Filesystem-backed cache store. Schema, layout, file format, atomicity, and locking are fixed by
    # [ADR-6](../../../docs/adr/6-cache-persistence-backend.md); callers use `#fetch_or_compute`
    # (producer-keyed), `#fetch_or_validate` (record-and-validate for discovered-dep caches, ADR-45), `#stats`,
    # `#evict!`, and `.disk_inventory`, plus the [`Rigor::Cache::Descriptor`](descriptor.rb) value object.
    #
    # Read failures (missing file, bad magic, format-version mismatch, corrupt SHA-256 trailer, un-inflatable
    # or unmarshal-able payload) are silently treated as cache misses; the producer block reruns and the next
    # write replaces the bad entry. The trailing SHA-256 catches accidental corruption (partial writes, FS
    # errors); it is **not** a security boundary, per ADR-2's trusted-gem trust model.
    class Store # rubocop:disable Metrics/ClassLength
      # On-disk byte-layout version. Bumped on incompatible format changes (independent of
      # {Descriptor::SCHEMA_VERSION}, which covers the descriptor schema rather than the byte layout). v2
      # (ADR-54 WD2): the value payload is zlib-deflated on write and inflated on read — Marshal blobs
      # compress to 13–16 % at an inflate cost an order of magnitude below their `Marshal.load`. v1 entries
      # fail the header check and read as silent misses; the `schema_version.txt` marker additionally carries
      # this version, so the first writable run after a bump clears the root and reclaims the unreadable
      # bytes.
      #
      # v3 (issue #696 review, second pass): `RBS::Location#_dump` now carries the buffer NAME rather than an
      # empty string, so an env blob written before this change reconstructs every location behind the
      # `<cached>` sentinel. That degrades gracefully — the sentinel is filtered, never printed as a path —
      # but `rbs.coverage.definition-build-failed` then omits its conflicting-files clause, so a warm run off
      # a pre-change blob says less than a cold run does, indefinitely: ADR-6's store never evicts.
      # `PAYLOAD_ABI_VERSION` already rebuilds across a RELEASE, so the exposure is a same-version tree; this
      # closes that window too, because "the same project reports differently depending on how you ran it" is
      # the defect the diagnostic exists to end and a stale blob reintroduces it.
      FORMAT_VERSION = 3

      # Payload ABI version. Store values are mostly Marshal blobs of Rigor/RBS objects, so a Rigor release
      # upgrade is an ABI boundary even when the byte layout and descriptor schema are unchanged. Folding the
      # gem version into the root marker makes installed-version upgrades rebuild rather than silently reuse a
      # blob whose class layout still happens to unmarshal.
      PAYLOAD_ABI_VERSION = Rigor::VERSION

      # The `generation_cap:` value declaring that a producer keeps MANY live entries under one id at once
      # (per-file and per-plugin producers): a generation count is not a staleness proxy there, so the
      # compaction pass in {#evict!} leaves the producer alone and only the size-based LRU pass can touch it.
      UNBOUNDED_GENERATIONS = :unbounded

      STALE_TEMP_FILE_AGE_SECONDS = 60 * 60

      # Header literal: 5-byte ASCII magic, 1-byte separator, 1-byte format version.
      HEADER = "RIGOR\x00#{FORMAT_VERSION.chr}".b.freeze

      VALID_PRODUCER_ID = /\A[a-z][a-z0-9._-]*\z/

      # @rbs root: String -- Cache root directory.
      # @rbs read_only: bool --
      #   When true, every disk-side side-effect is suppressed: `fetch_or_compute` still reads existing entries (hits,
      #   gated on a current `schema_version.txt` marker — see {#ensure_schema_version!}) and still runs the producer
      #   block on miss, but it does NOT write the produced value to disk, does NOT update the marker, and does NOT
      #   touch the on-disk root directory. The in-process memo is still populated so repeated lookups within the same
      #   run stay cheap. Used by editor mode so multiple buffer-mode invocations can read from the same cache
      #   concurrently without churning it. See `docs/design/20260516-editor-mode.md` § "Cache behaviour".
      def initialize(root:, read_only: false, max_bytes: nil)
        @root = root.to_s.dup.freeze
        @read_only = read_only
        @max_bytes = max_bytes&.then { |n| Integer(n) }
        # Tri-state: nil = not yet checked, true/false = the disk tier's availability for this Store's
        # lifetime (see {#ensure_schema_version!}).
        @disk_available = nil
        @hits = 0
        @misses = 0
        @writes = 0
        @by_producer = Hash.new { |h, k| h[k] = { hits: 0, misses: 0, writes: 0 } }
        # `producer_id => generation cap`, populated from the `generation_cap:` every fetch call declares (see
        # {#declare_generation_cap}). This is the bridge between the id STRINGS the fetch API takes and the
        # directory names {#evict!} walks: a producer id the Store never saw declared stays uncapped, which
        # errs toward under-evicting. Per-instance rather than process-global on purpose — a global mutable
        # registry would be a `Ractor` shareability hazard for pool mode, and the Store instance that wrote a
        # generation is the one whose `evict!` compacts it (`CLI::CheckCommand` calls
        # `runner.cache_store&.evict!`).
        @generation_caps = {}
        # Process-level in-memory layer keyed by `(producer_id, cache_key)`. Avoids the disk read +
        # `Marshal.load` cost (the dominant share of repeated cache-hit calls per stackprof) when many
        # short-lived `Analysis::Runner` instances share one `Store` — the spec process, the LSP daemon's
        # repeated re-check path, and any other "many runs, same project" loop. Keys are content-derived
        # (descriptor digests), so cross-fixture contamination is impossible.
        @memo = {}
        # `Analysis::Runner` walks files concurrently (file-level parallelism); the per-file workers share
        # one Store. The monitor guards `@memo` + the counter hashes against concurrent writes. The Monitor
        # is re-entrant so producer blocks can recursively consult the Store (e.g. one cache layer building
        # on another) without dead-locking.
        @monitor = Monitor.new
      end

      attr_reader :root

      # @rbs return: bool --
      #   Whether this Store suppresses disk writes (`schema_version.txt`, entry creation). Reads are unaffected.
      def read_only?
        @read_only
      end

      # Returns a frozen snapshot of this Store's per-run hit / miss / write counters. The bookkeeping is
      # in-memory only — every new `Store.new` starts at zero — so the counters reflect activity against this
      # specific instance rather than the on-disk cache state. Disk-level state is reported separately by
      # {.disk_inventory}.
      #
      # @rbs return: Hash[untyped, untyped] --
      #   `{ hits:, misses:, writes:, by_producer: { id => { hits:, misses:, writes: } } }`
      def stats
        @monitor.synchronize do
          per_producer = @by_producer.transform_values { |counts| counts.dup.freeze }.freeze
          { hits: @hits, misses: @misses, writes: @writes, by_producer: per_producer }.freeze
        end
      end

      # Walks the on-disk cache rooted at `root` and reports a producer-level inventory. Used by
      # `rigor check --cache-stats` to surface cache size and per-producer entry counts without depending on
      # in-process counters (which only reflect the current run).
      #
      # @rbs return: Hash[untyped, untyped] --
      #   `{ root:, schema_version:, total_entries:, total_bytes:, producers: [{ id:, entries:, bytes: }, ...] }`.
      #   When the root does not exist or has no schema-version marker, `schema_version` is nil and the producer list
      #   is empty.
      #
      # The `schema_version.txt` marker content. Covers BOTH invalidation axes: the descriptor schema and the
      # on-disk byte layout ({FORMAT_VERSION}, ADR-54). A format bump leaves the old entries permanently
      # unreadable (header mismatch → miss) but, alone, would never reclaim their bytes — they can sit below
      # the eviction cap forever. Folding the format version into the marker routes the bump through the
      # established clear-the-root path instead.
      def self.schema_marker_value
        "#{PAYLOAD_ABI_VERSION}.#{Descriptor::SCHEMA_VERSION}.#{FORMAT_VERSION}"
      end

      def self.disk_inventory(root:)
        root_s = root.to_s
        marker = File.join(root_s, "schema_version.txt")
        schema = File.file?(marker) ? File.read(marker).strip : nil

        producers = collect_producers(root_s)
        total_entries = producers.sum { |p| p[:entries] }
        total_bytes = producers.sum { |p| p[:bytes] }

        {
          root: root_s,
          schema_version: schema,
          total_entries: total_entries,
          total_bytes: total_bytes,
          producers: producers
        }
      end

      def self.collect_producers(root)
        return [] unless File.directory?(root)

        Dir.children(root).sort.filter_map do |child|
          subdir = File.join(root, child)
          next nil unless File.directory?(subdir)

          entries = Dir.glob(File.join(subdir, "**", "*.entry"))
          next nil if entries.empty?

          { id: child, entries: entries.size, bytes: entries.sum { |e| File.size(e) } }
        end
      end
      private_class_method :collect_producers

      # @rbs producer_id: String -- Stable cache namespace; only `[a-z][a-z0-9._-]*` is accepted.
      # @rbs generation_cap: Integer | Symbol --
      #   How many generations of this producer survive a compaction pass — a positive `Integer` for a whole-project
      #   producer (one live entry, older ones unreachable), or {UNBOUNDED_GENERATIONS} for a producer with many
      #   simultaneously-live entries. REQUIRED, and sourced from the producer's own declaration
      #   (`RbsCacheProducer.generation_cap`, `RunCacheKey::GENERATION_CAP`, `Plugin::Base.producer generation_cap:`)
      #   rather than invented at the call site. See {#evict!}.
      # @rbs params: Hash[untyped, untyped] --
      #   Producer inputs; mixed into the cache key via {Descriptor#cache_key_for}.
      # @rbs descriptor: Rigor::Cache::Descriptor -- The invalidation descriptor for the value being cached.
      # @rbs serialize: untyped --
      #   Optional callable that turns the producer's return value into a binary `String`. Defaults to
      #   `Marshal.dump(value).b`. Producers whose return values are not `Marshal`-clean (RBS-native objects with
      #   `RBS::Location` members, raw `IO`, …) MUST provide a serialiser. The pair `(serialize, deserialize)` MUST
      #   round-trip — a producer that reads with one strategy and writes with another corrupts its own cache slice.
      # @rbs deserialize: untyped --
      #   Optional callable that turns bytes back into the producer's value. Defaults to `Marshal.load`. Any exception
      #   (`StandardError`) raised by the deserialiser is treated as a cache miss — the entry is considered corrupt,
      #   the producer block reruns, and the next write overwrites it. This is consistent with the fault-tolerance
      #   contract for the default `Marshal.load` path. Value to cache. Cached value (loaded from disk on hit;
      #   produced by the block on miss).
      def fetch_or_compute(producer_id:, params:, descriptor:, generation_cap:,
                           serialize: nil, deserialize: nil, &block)
        validate_producer_id!(producer_id)
        declare_generation_cap(producer_id, generation_cap)
        disk = ensure_schema_version!

        key = descriptor.cache_key_for(producer_id: producer_id, params: params)
        memo_key = [producer_id, key].freeze
        memoed = @monitor.synchronize { @memo[memo_key] if @memo.key?(memo_key) }
        unless memoed.nil?
          @monitor.synchronize { record(:hits, producer_id) }
          return memoed
        end

        path = disk ? entry_path(producer_id, key) : nil
        cached = path && read_entry(path, deserialize: deserialize)
        unless cached.nil?
          @monitor.synchronize do
            record(:hits, producer_id)
            @memo[memo_key] = cached.value
          end
          return cached.value
        end

        value = block.call
        wrote = path && try_write_entry(path, descriptor, value, serialize: serialize)
        @monitor.synchronize do
          record(:misses, producer_id)
          record(:writes, producer_id) if wrote
          @memo[memo_key] = value
        end
        value
      end

      # ADR-45 — record-and-validate variant. Unlike {fetch_or_compute}, which keys the entry on its
      # descriptor (so the inputs MUST be known before running), this keys on `key_descriptor` (the stable
      # inputs known up front) and stores, alongside the value, a `dependency_descriptor` of the files the
      # value actually read — including inputs discovered DURING the computation (e.g. a plugin reading a
      # file mid-analysis). On the next run the stored dependencies are re-validated against the filesystem
      # ({Descriptor#fresh?}); a stale dependency forces a recompute.
      #
      # The block MUST return `[value, dependency_descriptor]`. Disk reads are not in-process-memoised —
      # validation always re-checks the filesystem — but a single run only looks up once.
      #
      # `generation_cap:` carries the same producer-declared compaction budget as {#fetch_or_compute}.
      def fetch_or_validate(producer_id:, key_descriptor:, generation_cap:, params: {},
                            serialize: nil, deserialize: nil)
        validate_producer_id!(producer_id)
        declare_generation_cap(producer_id, generation_cap)
        disk = ensure_schema_version!

        key = key_descriptor.cache_key_for(producer_id: producer_id, params: params)
        path = disk ? entry_path(producer_id, key) : nil
        cached = path && read_entry(path, deserialize: deserialize)
        if (validated = fresh_pair_value(cached))
          @monitor.synchronize { record(:hits, producer_id) }
          return validated[0]
        end

        value, dependency_descriptor = block_given? ? yield : [nil, Descriptor.new]
        wrote = path && try_write_entry(path, key_descriptor, [value, dependency_descriptor], serialize: serialize)
        @monitor.synchronize do
          record(:misses, producer_id)
          record(:writes, producer_id) if wrote
        end
        value
      end

      # ADR-87 WD4 — the READ half of {#fetch_or_validate} with no compute and no write: returns the cached
      # value on a fresh hit, nil on a miss / stale / unavailable-disk. The boot-slimming hit probe calls this
      # to serve a run's diagnostics WITHOUT loading the inference engine — it never runs a producer block, so
      # there is nothing to write. Records a hit (for `--cache-stats` parity) but never a miss (a probe miss
      # hands off to the full path, which records its own).
      #
      # Takes no `generation_cap:`: a pure read creates no generation, so a run that only ever peeks has
      # nothing to compact. The write path for the same producer declares the cap.
      def peek_validated(producer_id:, key_descriptor:, params: {}, deserialize: nil)
        validate_producer_id!(producer_id)
        return nil unless ensure_schema_version!

        key = key_descriptor.cache_key_for(producer_id: producer_id, params: params)
        cached = read_entry(entry_path(producer_id, key), deserialize: deserialize)
        validated = fresh_pair_value(cached)
        return nil if validated.nil?

        @monitor.synchronize { record(:hits, producer_id) }
        validated[0]
      end

      # ADR-6 § "Eviction" — compaction pass over the on-disk cache. No-op when the store is read-only.
      #
      # The generation cap of pass 2 comes from what the producers themselves declared through this Store's
      # fetch calls (`generation_cap:`), NOT from a maintained table of producer ids: a producer id this
      # Store never saw is left alone. That is deliberately the safe direction — a producer that was not
      # consulted this run also wrote no new generation, so the only entries this can skip are ones that were
      # already sitting there.
      #
      # Stale temp file cleanup and the generation cap run regardless of `max_bytes:` — they reclaim
      # provably-dead bytes (leaked temp files, unreachable content-keyed generations) rather than enforcing a
      # size budget, so an explicitly unbounded store (`max_bytes: nil`) still benefits from them. The
      # size-based LRU pass below stays gated on `max_bytes:` being configured: it walks all remaining
      # `.entry` files, sorts by mtime ascending (oldest = least recently used), and unlinks from the oldest
      # until the total is at or below the cap. Touch-on-disk-read ({read_entry}) is the cross-process LRU
      # signal: every disk hit (not in-process-memo hit) updates the mtime so recently-read entries survive
      # the eviction pass. Any FS error is swallowed — eviction must never break a run.
      def evict!
        return if @read_only

        cleanup_stale_temp_files
        entries = evict_excess_generations(collect_entry_stats)
        return if @max_bytes.nil?

        total = entries.sum { |e| e[:bytes] }
        return if total <= @max_bytes

        entries.sort_by! { |e| e[:mtime] }
        entries.each do |entry|
          break if total <= @max_bytes

          total -= entry[:bytes] if unlink_entry_and_shard?(entry[:path])
        end
        nil
      rescue StandardError
        nil
      end

      private

      Entry = Data.define(:descriptor_bytes, :value)
      private_constant :Entry

      # A record-and-validate entry is a fresh hit iff it deserialised to a `[value, dependency_descriptor]`
      # pair whose descriptor still validates against the filesystem. Returns the pair on a fresh hit, nil
      # otherwise. Shared by {#fetch_or_validate} and {#peek_validated} so both apply identical hit criteria.
      def fresh_pair_value(cached)
        return nil if cached.nil?

        pair = cached.value
        return nil unless pair.is_a?(Array) && pair.size == 2 &&
                          pair[1].is_a?(Descriptor) && pair[1].fresh?

        pair
      end

      def record(counter, producer_id)
        case counter
        when :hits then @hits += 1
        when :misses then @misses += 1
        when :writes then @writes += 1
        end
        @by_producer[producer_id][counter] += 1
      end

      def validate_producer_id!(producer_id)
        return if producer_id.is_a?(String) && producer_id.match?(VALID_PRODUCER_ID)

        raise ArgumentError,
              "producer_id must match #{VALID_PRODUCER_ID.inspect}, got #{producer_id.inspect}"
      end

      # Records the producer's declared compaction budget for {#evict!}. Every fetch call carries it, so a
      # producer cannot reach disk without stating one — the failure mode the previous hardcoded id table
      # had (a new whole-project producer silently uncapped) is not expressible.
      #
      # Two DIFFERENT caps for one producer id in one process is a producer bug, not a policy: whichever the
      # compaction pass picked would be arbitrary. It raises, consistent with the serializer-contract
      # violations {#try_write_entry} deliberately lets through.
      def declare_generation_cap(producer_id, generation_cap)
        validate_generation_cap!(producer_id, generation_cap)
        @monitor.synchronize do
          previous = @generation_caps[producer_id]
          if !previous.nil? && previous != generation_cap
            raise ArgumentError,
                  "producer #{producer_id.inspect} declared generation_cap #{generation_cap.inspect} after " \
                  "#{previous.inspect}; one producer id must declare one cap"
          end

          @generation_caps[producer_id] = generation_cap
        end
      end

      def validate_generation_cap!(producer_id, generation_cap)
        return if generation_cap == UNBOUNDED_GENERATIONS
        return if generation_cap.is_a?(Integer) && generation_cap.positive?

        raise ArgumentError,
              "producer #{producer_id.inspect} must declare generation_cap as a positive Integer (a " \
              "whole-project producer: how many generations survive compaction) or " \
              "#{UNBOUNDED_GENERATIONS.inspect} (many entries live at once), got #{generation_cap.inspect}"
      end

      def entry_path(producer_id, key)
        File.join(@root, producer_id, key[0, 2], "#{key[2..]}.entry")
      end

      # Reads and validates one entry file. Any failure (missing, short, bad magic, bad version, bad
      # checksum, unmarshal-able) returns nil so the caller treats it as a cache miss.
      def read_entry(path, deserialize: nil)
        return nil unless File.file?(path)

        bytes = File.binread(path)
        return nil unless envelope_valid?(bytes)

        body = bytes.byteslice(HEADER.bytesize, bytes.bytesize - HEADER.bytesize - 32)
        descriptor_bytes, value_bytes = parse_body(body)
        return nil if descriptor_bytes.nil?

        value = safe_load(value_bytes, deserialize)
        return nil if value.equal?(LOAD_FAILED)

        touch_for_lru(path) if @max_bytes
        Entry.new(descriptor_bytes, value)
      end

      # Validates the magic + format-version header and the trailing SHA-256 over everything before the
      # trailer.
      def envelope_valid?(bytes)
        return false if bytes.bytesize < HEADER.bytesize + 32
        return false unless bytes.byteslice(0, HEADER.bytesize) == HEADER

        trailer = bytes.byteslice(bytes.bytesize - 32, 32)
        Digest::SHA256.digest(bytes.byteslice(0, bytes.bytesize - 32)) == trailer
      end

      # Splits the body into (descriptor_bytes, value_bytes). Returns `[nil, nil]` on a malformed varint or
      # length-overrun.
      def parse_body(body)
        offset = 0
        descriptor_len, offset = read_varint(body, offset)
        return [nil, nil] if descriptor_len.nil? || offset + descriptor_len > body.bytesize

        descriptor_bytes = body.byteslice(offset, descriptor_len)
        offset += descriptor_len

        value_len, offset = read_varint(body, offset)
        return [nil, nil] if value_len.nil? || offset + value_len != body.bytesize

        value_bytes = body.byteslice(offset, value_len)
        [descriptor_bytes, value_bytes]
      end

      LOAD_FAILED = Object.new.freeze
      private_constant :LOAD_FAILED

      # Inflates the stored value payload (ADR-54 WD2), then hands the raw bytes to the deserialiser. Any
      # failure — corrupt deflate stream included — reads as a miss.
      def safe_load(bytes, deserialize)
        raw = Zlib::Inflate.inflate(bytes)
        if deserialize
          deserialize.call(raw)
        else
          Marshal.load(raw) # rubocop:disable Security/MarshalLoad
        end
      rescue StandardError
        LOAD_FAILED
      end

      def write_entry(path, descriptor, value, serialize: nil)
        FileUtils.mkdir_p(File.dirname(path))

        descriptor_bytes = descriptor.to_canonical_bytes
        value_bytes = Zlib::Deflate.deflate(serialize_value(value, serialize))

        body = +"".b
        body << HEADER
        write_varint(body, descriptor_bytes.bytesize)
        body << descriptor_bytes
        write_varint(body, value_bytes.bytesize)
        body << value_bytes
        body << Digest::SHA256.digest(body)

        atomically_replace(path, body)
      end

      def serialize_value(value, serialize)
        return Marshal.dump(value).b if serialize.nil?

        bytes = serialize.call(value)
        unless bytes.is_a?(String)
          raise TypeError,
                "custom serialize must return a String, got #{bytes.class}"
        end

        bytes.b
      end

      def atomically_replace(path, body)
        File.open(path, File::RDWR | File::CREAT, 0o644) do |lock_fd|
          lock_fd.flock(File::LOCK_EX)
          tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
          begin
            File.open(tmp, "wb") do |f|
              f.write(body)
              f.fsync
            end
            File.rename(tmp, path)
          ensure
            # A failed write/rename must not leak its temp file — rely on the 1-hour `cleanup_stale_temp_files`
            # sweep only as a backstop for crashes that skip this ensure entirely.
            unlink_entry(tmp) if File.exist?(tmp)
          end
          fsync_directory(File.dirname(path))
        end
      end

      # Checks (and, for a writable store, repairs) the `schema_version.txt` marker, and reports whether the
      # disk tier is usable for the rest of this Store's lifetime. The result is memoized in `@disk_available`
      # — one check per Store is enough; a benign double-check under a thread race would just repeat
      # idempotent work.
      #
      # A writable store clears the cache root and rewrites the marker on a stale/missing marker, then reports
      # available. A read-only store never touches the root — no mkdir, no marker write, no destructive clear
      # — so it reports available ONLY when the on-disk marker already matches current exactly; a stale or
      # missing marker (e.g. a Rigor upgrade with no writable run yet, as in LSP / editor mode) reports
      # unavailable rather than risk unmarshalling a payload from a different ABI. Any filesystem failure
      # (permission, disk full, deleted root) also reports unavailable, degrading this Store instance to
      # in-memory-memo-only for the rest of its lifetime — the producer block still runs, its result still
      # lands in `@memo`, and disk reads/writes are simply skipped.
      def ensure_schema_version!
        return @disk_available unless @disk_available.nil?

        @disk_available = @read_only ? read_only_marker_current? : repair_writable_marker!
      end

      def read_only_marker_current?
        marker = File.join(@root, "schema_version.txt")
        return false unless File.file?(marker)

        File.read(marker).strip == self.class.schema_marker_value
      rescue StandardError
        false
      end

      def repair_writable_marker!
        FileUtils.mkdir_p(@root)
        marker = File.join(@root, "schema_version.txt")
        current = self.class.schema_marker_value

        if File.file?(marker)
          on_disk = File.read(marker).strip
          return true if on_disk == current

          clear_cache_root!
        end

        FileUtils.mkdir_p(@root)
        File.write(marker, "#{current}\n")
        true
      rescue StandardError
        false
      end

      def clear_cache_root!
        Dir.children(@root).each do |entry|
          FileUtils.rm_rf(File.join(@root, entry))
        end
      end

      # Shared write path for both {#fetch_or_compute} and {#fetch_or_validate}. A cache write must never
      # break the run: filesystem-side failures (permission, disk full, deleted root, read-only mount) are
      # swallowed and read as "did not write". Programmer errors — a custom serializer that doesn't return a
      # `String`, or any other producer contract violation — still raise so the bug is visible.
      def try_write_entry(path, descriptor, value, serialize: nil)
        return false if @read_only

        write_entry(path, descriptor, value, serialize: serialize)
        true
      rescue SystemCallError, IOError
        false
      end

      # Best-effort durability for the rename itself. Some platforms cannot fsync directories (or do not need to),
      # so failures are ignored; the entry envelope still turns any lost/partial write into a miss.
      def fsync_directory(dir)
        File.open(dir, File::RDONLY, &:fsync)
      rescue StandardError
        nil
      end

      # LEB128 unsigned varint encoder/decoder. Lengths fit easily in five bytes (cap at 2^35); the cache
      # layer never writes a value larger than that in practice.
      def write_varint(bytes, value)
        raise ArgumentError, "varint must be non-negative" if value.negative?

        loop do
          if value < 0x80
            bytes << [value].pack("C")
            return
          end

          bytes << [(value & 0x7F) | 0x80].pack("C")
          value >>= 7
        end
      end

      # Updates both atime and mtime of `path` to the current time — the cross-process LRU signal used by
      # {evict!}. Best-effort: any FS error (read-only mount, deleted file) is silently ignored.
      def touch_for_lru(path)
        now = Time.now
        File.utime(now, now, path)
      rescue StandardError
        nil
      end

      def cleanup_stale_temp_files
        cutoff = Time.now - STALE_TEMP_FILE_AGE_SECONDS
        Dir.glob(File.join(@root, "**", "*.tmp.*")).each do |path|
          next unless File.file?(path)
          next if File.mtime(path) > cutoff

          unlink_entry_and_shard?(path)
        rescue StandardError
          next
        end
      rescue StandardError
        nil
      end

      def evict_excess_generations(entries)
        caps = @monitor.synchronize { @generation_caps.dup }
        removed = {}
        entries.group_by { |entry| entry[:producer] }.each do |producer, producer_entries|
          cap = caps[producer]
          cap = nil if cap == UNBOUNDED_GENERATIONS
          next if cap.nil? || producer_entries.size <= cap

          excess = producer_entries.sort_by { |entry| [entry[:mtime], entry[:path]] }
                                   .first(producer_entries.size - cap)
          excess.each { |entry| removed[entry[:path]] = true if unlink_entry_and_shard?(entry[:path]) }
        end
        return entries if removed.empty?

        entries.reject { |entry| removed[entry[:path]] }
      end

      def unlink_entry(path)
        File.unlink(path)
        true
      rescue StandardError
        false
      end

      # {#unlink_entry} plus a best-effort {#rmdir_if_empty} of the shard directory the unlinked file left
      # behind. Shared by every eviction/sweep pass so an emptied shard is cleaned up wherever an entry (or
      # stale temp file) is removed, per the issue #216 fossil fix.
      def unlink_entry_and_shard?(path)
        return false unless unlink_entry(path)

        rmdir_if_empty(File.dirname(path))
        true
      end

      # Removes `dir` — a shard directory (`entry_path`'s `key[0, 2]` component) — when the unlink that
      # just preceded this call was the one to empty it. Best-effort and rescued the same way
      # {#unlink_entry} is: a concurrent writer's `FileUtils.mkdir_p` recreating the shard between the
      # unlink and this call (`Errno::ENOTEMPTY`) or another pass already having removed it
      # (`Errno::ENOENT`) are both benign outcomes, never a reason to break the eviction/sweep pass. This
      # is purely cosmetic (inode reclaim) — it never decides which ENTRIES are evicted, only tidies the
      # directory left behind once they are gone.
      def rmdir_if_empty(dir)
        Dir.rmdir(dir)
      rescue StandardError
        nil
      end

      # Returns an array of `{ path:, producer:, mtime:, bytes: }` hashes for every `.entry` file under the
      # cache root, skipping unreadable entries.
      def collect_entry_stats
        Dir.glob(File.join(@root, "**", "*.entry")).filter_map do |path|
          stat = File.stat(path)
          producer = producer_id_for_entry(path)
          next nil if producer.nil?

          { path: path, producer: producer, mtime: stat.mtime, bytes: stat.size }
        rescue StandardError
          nil
        end
      end

      def producer_id_for_entry(path)
        root_prefix = @root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}"
        return nil unless path.start_with?(root_prefix)

        producer = path.delete_prefix(root_prefix).split(File::SEPARATOR, 2).first
        producer.empty? ? nil : producer
      end

      def read_varint(bytes, offset)
        result = 0
        shift = 0
        loop do
          return [nil, offset] if offset >= bytes.bytesize

          byte = bytes.getbyte(offset)
          offset += 1
          result |= (byte & 0x7F) << shift
          return [result, offset] if byte < 0x80

          shift += 7
          return [nil, offset] if shift > 35
        end
      end
    end
  end
end
