# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "monitor"
require "securerandom"

require_relative "descriptor"

module Rigor
  module Cache
    # Filesystem-backed cache store. Schema, layout, file format,
    # atomicity, and locking are fixed by [ADR-6](../../../docs/adr/6-cache-persistence-backend.md);
    # callers see the [`Rigor::Cache::Descriptor`](descriptor.rb)
    # value object plus this class' `#fetch_or_compute` entry point
    # and nothing else.
    #
    # Read failures (missing file, bad magic, format-version mismatch,
    # corrupt SHA-256 trailer, unmarshal-able payload) are silently
    # treated as cache misses; the producer block reruns and the
    # next write replaces the bad entry. The trailing SHA-256 catches
    # accidental corruption (partial writes, FS errors); it is **not**
    # a security boundary, per ADR-2's trusted-gem trust model.
    class Store # rubocop:disable Metrics/ClassLength
      # Header literal: 5-byte ASCII magic, 1-byte separator, 1-byte
      # format version. Bumped on incompatible on-disk format changes
      # (independent of {Descriptor::SCHEMA_VERSION}, which covers
      # the descriptor schema rather than the byte layout).
      HEADER = "RIGOR\x00\x01".b.freeze

      VALID_PRODUCER_ID = /\A[a-z][a-z0-9._-]*\z/

      # @param root [String] cache root directory.
      # @param read_only [Boolean] when true, every disk-side
      #   side-effect is suppressed: `fetch_or_compute` still
      #   reads existing entries (hits) and still runs the
      #   producer block on miss, but it does NOT write the
      #   produced value to disk, does NOT update the
      #   `schema_version.txt` marker, and does NOT touch the
      #   on-disk root directory. The in-process memo is still
      #   populated so repeated lookups within the same run stay
      #   cheap. Used by editor mode so multiple buffer-mode
      #   invocations can read from the same cache concurrently
      #   without churning it. See
      #   `docs/design/20260516-editor-mode.md` § "Cache behaviour".
      def initialize(root:, read_only: false)
        @root = root.to_s.dup.freeze
        @read_only = read_only
        @hits = 0
        @misses = 0
        @writes = 0
        @by_producer = Hash.new { |h, k| h[k] = { hits: 0, misses: 0, writes: 0 } }
        # Process-level in-memory layer keyed by
        # `(producer_id, cache_key)`. Avoids the disk read +
        # `Marshal.load` cost (the dominant share of repeated
        # cache-hit calls per stackprof) when many short-lived
        # `Analysis::Runner` instances share one `Store` — the
        # spec process, the LSP daemon's repeated re-check
        # path, and any other "many runs, same project" loop.
        # Keys are content-derived (descriptor digests), so
        # cross-fixture contamination is impossible.
        @memo = {}
        # `Analysis::Runner` walks files concurrently (file-
        # level parallelism); the per-file workers share one
        # Store. The monitor guards `@memo` + the counter
        # hashes against concurrent writes. The Monitor is
        # re-entrant so producer blocks can recursively
        # consult the Store (e.g. one cache layer building on
        # another) without dead-locking.
        @monitor = Monitor.new
      end

      attr_reader :root

      # @return [Boolean] whether this Store suppresses disk writes
      #   (`schema_version.txt`, entry creation). Reads are
      #   unaffected.
      def read_only?
        @read_only
      end

      # Returns a frozen snapshot of this Store's per-run hit / miss /
      # write counters. The bookkeeping is in-memory only — every new
      # `Store.new` starts at zero — so the counters reflect activity
      # against this specific instance rather than the on-disk cache
      # state. Disk-level state is reported separately by
      # {.disk_inventory}.
      #
      # @return [Hash] `{ hits:, misses:, writes:, by_producer: { id => { hits:, misses:, writes: } } }`
      def stats
        @monitor.synchronize do
          per_producer = @by_producer.transform_values { |counts| counts.dup.freeze }.freeze
          { hits: @hits, misses: @misses, writes: @writes, by_producer: per_producer }.freeze
        end
      end

      # Walks the on-disk cache rooted at `root` and reports a
      # producer-level inventory. Used by `rigor check --cache-stats`
      # to surface cache size and per-producer entry counts without
      # depending on in-process counters (which only reflect the
      # current run).
      #
      # @return [Hash] `{ root:, schema_version:, total_entries:,
      #   total_bytes:, producers: [{ id:, entries:, bytes: }, ...] }`.
      #   When the root does not exist or has no schema-version
      #   marker, `schema_version` is nil and the producer list is
      #   empty.
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

      # @param producer_id [String] stable cache namespace; only
      #   `[a-z][a-z0-9._-]*` is accepted.
      # @param params [Hash] producer inputs; mixed into the cache key
      #   via {Descriptor#cache_key_for}.
      # @param descriptor [Rigor::Cache::Descriptor] the invalidation
      #   descriptor for the value being cached.
      # @param serialize [#call, nil] optional callable that turns the
      #   producer's return value into a binary `String`. Defaults to
      #   `Marshal.dump(value).b`. Producers whose return values are
      #   not `Marshal`-clean (RBS-native objects with `RBS::Location`
      #   members, raw `IO`, …) MUST provide a serialiser. The pair
      #   `(serialize, deserialize)` MUST round-trip — a producer that
      #   reads with one strategy and writes with another corrupts
      #   its own cache slice.
      # @param deserialize [#call, nil] optional callable that turns
      #   bytes back into the producer's value. Defaults to
      #   `Marshal.load`. Any exception (`StandardError`) raised by
      #   the deserialiser is treated as a cache miss — the entry is
      #   considered corrupt, the producer block reruns, and the
      #   next write overwrites it. This is consistent with the
      #   fault-tolerance contract for the default `Marshal.load`
      #   path.
      # @yieldreturn the value to cache.
      # @return the cached value (loaded from disk on hit; produced by
      #   the block on miss).
      def fetch_or_compute(producer_id:, params:, descriptor:,
                           serialize: nil, deserialize: nil, &block)
        validate_producer_id!(producer_id)
        ensure_schema_version!

        key = descriptor.cache_key_for(producer_id: producer_id, params: params)
        memo_key = [producer_id, key].freeze
        memoed = @monitor.synchronize { @memo[memo_key] if @memo.key?(memo_key) }
        unless memoed.nil?
          @monitor.synchronize { record(:hits, producer_id) }
          return memoed
        end

        path = entry_path(producer_id, key)
        cached = read_entry(path, deserialize: deserialize)
        unless cached.nil?
          @monitor.synchronize do
            record(:hits, producer_id)
            @memo[memo_key] = cached.value
          end
          return cached.value
        end

        value = block.call
        write_entry(path, descriptor, value, serialize: serialize) unless @read_only
        @monitor.synchronize do
          record(:misses, producer_id)
          record(:writes, producer_id) unless @read_only
          @memo[memo_key] = value
        end
        value
      end

      private

      Entry = Data.define(:descriptor_bytes, :value)
      private_constant :Entry

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

      def entry_path(producer_id, key)
        File.join(@root, producer_id, key[0, 2], "#{key[2..]}.entry")
      end

      # Reads and validates one entry file. Any failure (missing,
      # short, bad magic, bad version, bad checksum, unmarshal-able)
      # returns nil so the caller treats it as a cache miss.
      def read_entry(path, deserialize: nil)
        return nil unless File.file?(path)

        bytes = File.binread(path)
        return nil unless envelope_valid?(bytes)

        body = bytes.byteslice(HEADER.bytesize, bytes.bytesize - HEADER.bytesize - 32)
        descriptor_bytes, value_bytes = parse_body(body)
        return nil if descriptor_bytes.nil?

        value = safe_load(value_bytes, deserialize)
        return nil if value.equal?(LOAD_FAILED)

        Entry.new(descriptor_bytes, value)
      end

      # Validates the magic + format-version header and the trailing
      # SHA-256 over everything before the trailer.
      def envelope_valid?(bytes)
        return false if bytes.bytesize < HEADER.bytesize + 32
        return false unless bytes.byteslice(0, HEADER.bytesize) == HEADER

        trailer = bytes.byteslice(bytes.bytesize - 32, 32)
        Digest::SHA256.digest(bytes.byteslice(0, bytes.bytesize - 32)) == trailer
      end

      # Splits the body into (descriptor_bytes, value_bytes). Returns
      # `[nil, nil]` on a malformed varint or length-overrun.
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

      def safe_load(bytes, deserialize)
        if deserialize
          deserialize.call(bytes)
        else
          Marshal.load(bytes) # rubocop:disable Security/MarshalLoad
        end
      rescue StandardError
        LOAD_FAILED
      end

      def write_entry(path, descriptor, value, serialize: nil)
        FileUtils.mkdir_p(File.dirname(path))

        descriptor_bytes = descriptor.to_canonical_bytes
        value_bytes = serialize_value(value, serialize)

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
          File.open(tmp, "wb") do |f|
            f.write(body)
            f.fsync
          end
          File.rename(tmp, path)
        end
      end

      def ensure_schema_version!
        # Read-only stores never touch the cache root — no mkdir,
        # no marker write, no destructive clear on schema
        # mismatch. A stale or wrong-schema marker simply yields
        # nothing back (entries read through the version check
        # are content-keyed, so a write under the new schema
        # never collides with a read under the old). The next
        # writable run will repair the cache.
        return if @read_only

        FileUtils.mkdir_p(@root)
        marker = File.join(@root, "schema_version.txt")
        current = Descriptor::SCHEMA_VERSION.to_s

        if File.file?(marker)
          on_disk = File.read(marker).strip
          return if on_disk == current

          clear_cache_root!
        end

        FileUtils.mkdir_p(@root)
        File.write(marker, "#{current}\n")
      end

      def clear_cache_root!
        Dir.children(@root).each do |entry|
          FileUtils.rm_rf(File.join(@root, entry))
        end
      end

      # LEB128 unsigned varint encoder/decoder. Lengths fit easily in
      # five bytes (cap at 2^35); the cache layer never writes a value
      # larger than that in practice.
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
