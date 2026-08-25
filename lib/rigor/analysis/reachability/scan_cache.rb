# frozen_string_literal: true

require "digest"
require "fileutils"
require "zlib"

require_relative "../../version"

module Rigor
  module Analysis
    module Reachability
      # ADR-102 — the warm cache for `rigor unused`'s two per-file passes: the Prism reachability
      # scan over `.rb` / `.rake` files, and the capital-run extraction over template files. Both
      # passes are pure functions of one file's bytes, and both were measured re-running in full on
      # every invocation (2.0 s of a 2.6 s warm run on Mastodon; the Marshal restore is 25× cheaper
      # than the rescan, `docs/notes/20260825-feature-warm-cold-corpus-perf.md`).
      #
      # One self-validating zlib-Marshal blob under the cache root, the ADR-46 IncrementalSnapshot
      # shape rather than an ADR-54 `Cache::Store` producer: the sound unit of reuse is the FILE
      # (any subset of files may change between runs), so the payload carries a stat signature per
      # entry and validates each on read, where a store entry validates all-or-nothing and a miss
      # would throw away every unchanged file's work. The whole-project answer stays complete —
      # every file is still consulted every run; an unchanged one contributes its cached product.
      #
      # Fail-soft everywhere: a missing, torn, or stale-schema blob is an empty cache, and a file
      # whose signature cannot be taken is computed and never recorded. Nothing here can change
      # what the report says — only whether a per-file product was recomputed to say it.
      class ScanCache
        SCHEMA = 1
        FILE_NAME = "reachability-scan.bundle"

        # The sources whose behaviour the cached products embody. Digested into the header so a
        # checkout that edits the scan invalidates its survey targets' bundles without anyone
        # remembering to bump {SCHEMA} — the `Cache::EngineSource` idea, scoped to this feature.
        SOURCE_FILES = [
          File.expand_path("scan.rb", __dir__),
          File.expand_path(__FILE__)
        ].freeze

        # A file modified within this window of the recording instant is computed but never
        # recorded — the FileDigest racy-write guard, one tier simpler because a refused signature
        # costs one rescan on the next run, never a wrong answer.
        RACY_WINDOW_NS = 2_000_000_000
        private_constant :RACY_WINDOW_NS

        # @param cache_path [String, nil] the configuration's cache root; nil or empty is an inert
        #   cache (every fetch computes, nothing persists).
        # @param target_ruby [String, nil] parse-affecting configuration, part of the identity.
        def self.open(cache_path, target_ruby: nil)
          return new(path: nil, header: nil) if cache_path.nil? || cache_path.to_s.empty?

          new(path: File.join(cache_path.to_s, FILE_NAME),
              header: "#{SCHEMA}:#{Rigor::VERSION}:#{target_ruby}:#{source_digest}")
        end

        def self.source_digest
          Digest::SHA256.hexdigest(SOURCE_FILES.map { |path| File.read(path) }.join)
        rescue StandardError
          "unreadable"
        end

        def initialize(path:, header:)
          @path = path
          @header = header
          @entries = load_entries
          @live = {}
          @dirty = false
        end

        # Serves the cached product for `(kind, path)` while the file's stat signature holds;
        # otherwise computes via the block and records the fresh product.
        def serve(kind, path)
          key = [kind, path]
          sig = signature(path)
          cached = @entries[key]
          if cached && sig && cached[0] == sig
            @live[key] = cached
            return cached[1]
          end

          value = yield
          @live[key] = [sig, value] if sig
          @dirty = true
          value
        end

        # Best-effort persist, only when something changed. Carries forward entries this run never
        # consulted (a path-argument run must not shrink the full-project bundle) but drops the ones
        # whose file no longer exists; tmp-then-rename so a torn write is never read back.
        def save
          return if @path.nil? || !@dirty

          keep = @entries.merge(@live).select { |(_, path), _| File.exist?(path) }
          FileUtils.mkdir_p(File.dirname(@path))
          tmp = "#{@path}.#{Process.pid}.tmp"
          File.binwrite(tmp, Zlib::Deflate.deflate(Marshal.dump([@header, keep])))
          File.rename(tmp, @path)
          nil
        rescue StandardError
          FileUtils.rm_f(tmp) if tmp
          nil
        end

        private

        def load_entries
          return {} if @path.nil?

          # Same trust model as the ADR-45 store and the ADR-46 snapshot: the blob lives in the
          # project's own cache directory and a corrupt one degrades to an empty cache.
          header, entries = Marshal.load(Zlib::Inflate.inflate(File.binread(@path))) # rubocop:disable Security/MarshalLoad
          header == @header && entries.is_a?(Hash) ? entries : {}
        rescue StandardError
          {}
        end

        def signature(path)
          st = File.stat(path)
          mtime_ns = (st.mtime.to_i * 1_000_000_000) + st.mtime.nsec
          now_ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
          return nil if mtime_ns >= now_ns - RACY_WINDOW_NS

          [st.size, mtime_ns, (st.ctime.to_i * 1_000_000_000) + st.ctime.nsec, st.ino]
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
