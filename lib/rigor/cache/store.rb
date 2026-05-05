# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"

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

      def initialize(root:)
        @root = root.to_s.dup.freeze
      end

      attr_reader :root

      # @param producer_id [String] stable cache namespace; only
      #   `[a-z][a-z0-9._-]*` is accepted.
      # @param params [Hash] producer inputs; mixed into the cache key
      #   via {Descriptor#cache_key_for}.
      # @param descriptor [Rigor::Cache::Descriptor] the invalidation
      #   descriptor for the value being cached.
      # @yieldreturn the value to cache (must be `Marshal.dump`-able).
      # @return the cached value (loaded from disk on hit; produced by
      #   the block on miss).
      def fetch_or_compute(producer_id:, params:, descriptor:, &block)
        validate_producer_id!(producer_id)
        ensure_schema_version!

        key = descriptor.cache_key_for(producer_id: producer_id, params: params)
        path = entry_path(producer_id, key)

        cached = read_entry(path)
        return cached.value unless cached.nil?

        value = block.call
        write_entry(path, descriptor, value)
        value
      end

      private

      Entry = Data.define(:descriptor_bytes, :value)
      private_constant :Entry

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
      def read_entry(path)
        return nil unless File.file?(path)

        bytes = File.binread(path)
        return nil unless envelope_valid?(bytes)

        body = bytes.byteslice(HEADER.bytesize, bytes.bytesize - HEADER.bytesize - 32)
        descriptor_bytes, value_bytes = parse_body(body)
        return nil if descriptor_bytes.nil?

        value = safe_marshal_load(value_bytes)
        return nil if value.equal?(MARSHAL_LOAD_FAILED)

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

      MARSHAL_LOAD_FAILED = Object.new.freeze
      private_constant :MARSHAL_LOAD_FAILED

      def safe_marshal_load(bytes)
        Marshal.load(bytes) # rubocop:disable Security/MarshalLoad
      rescue StandardError
        MARSHAL_LOAD_FAILED
      end

      def write_entry(path, descriptor, value)
        FileUtils.mkdir_p(File.dirname(path))

        descriptor_bytes = descriptor.to_canonical_bytes
        value_bytes = Marshal.dump(value).b

        body = +"".b
        body << HEADER
        write_varint(body, descriptor_bytes.bytesize)
        body << descriptor_bytes
        write_varint(body, value_bytes.bytesize)
        body << value_bytes
        body << Digest::SHA256.digest(body)

        atomically_replace(path, body)
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
