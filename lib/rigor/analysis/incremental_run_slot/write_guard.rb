# frozen_string_literal: true

require "fileutils"
require "securerandom"

require_relative "../incremental_run_slot"
require_relative "../../cache/file_digest"
require_relative "../../cache/incremental_snapshot"

module Rigor
  module Analysis
    module IncrementalRunSlot
      # ADR-45 WD2 (#1507) — whether a run may record its answer at all. A slot's rows and key are built when the
      # run ENDS, and every one of them must still describe the tree the run analysed: a save that lands while the
      # run reads — an editor's, a `bundle install`'s — would otherwise leave the slot vouching for bytes the
      # analysis never saw, and the probe would serve the pre-save answer against the post-save tree.
      #
      # So the session takes a mark before the run reads anything ({.start}) and asks {#admits?} before it
      # writes. The mark is the filesystem's own clock, read off the change time of a file written for the
      # purpose: a timestamp compared across clocks misses an edit that lands inside a coarse filesystem's tick,
      # and change times (unlike modification times) cannot be set back by `cp -p` or `touch -d`. Declining to
      # write is always safe; it leaves the next null run on the full path.
      class WriteGuard
        STAMP_DIR = "incremental"
        private_constant :STAMP_DIR

        # Takes the mark, or nil when no stamp can be written (the store is then not one a slot is written to).
        def self.start(configuration:, roots:, cache_root:, fingerprint:)
          started_ns = stamp_ctime_ns(cache_root)
          key = IncrementalRunSlot.key(configuration: configuration, target: Target.new(files: [], roots: roots))
          return nil if started_ns.nil? || key.nil?

          new(configuration: configuration, roots: roots, fingerprint: fingerprint,
              key_bytes: key.to_canonical_bytes, started_ns: started_ns)
        end

        def self.stamp_ctime_ns(cache_root)
          dir = File.join(cache_root.to_s, STAMP_DIR)
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "run-#{Process.pid}-#{SecureRandom.hex(4)}.stamp")
          File.write(path, "")
          Cache::FileDigest.ns_of(File.stat(path).ctime)
        rescue SystemCallError, IOError
          nil
        ensure
          FileUtils.rm_f(path) if path
        end
        private_class_method :stamp_ctime_ns

        def initialize(configuration:, roots:, fingerprint:, key_bytes:, started_ns:)
          @configuration = configuration
          @roots = roots
          @fingerprint = fingerprint
          @key_bytes = key_bytes
          @started_ns = started_ns
        end

        # True when nothing the slot would vouch for moved since the mark:
        #
        # - the key's non-file inputs, the lockfiles above all, digest as they did (the key is otherwise read
        #   at write time, off the tree as it is then);
        # - the snapshot fingerprint the run was keyed by still matches (its `sig:` and lockfile parts);
        # - no file a row names changed after the mark, and no directory a glob row lists gained or lost an
        #   entry after it, nor, for a stat-mode glob, did any file it matches change.
        #
        # A file that is gone passes: its row is stale already, and validation says so.
        def admits?(dependencies)
          key = IncrementalRunSlot.key(configuration: @configuration, target: Target.new(files: [], roots: @roots))
          return false unless key && key.to_canonical_bytes == @key_bytes
          return false unless Cache::IncrementalSnapshot.fingerprint(configuration: @configuration,
                                                                     roots: @roots) == @fingerprint

          files_unchanged?(dependencies.files) && globs_unchanged?(dependencies.globs)
        rescue StandardError
          false
        end

        private

        def files_unchanged?(entries)
          seen = Set.new
          entries.none? do |entry|
            next false if entry.comparator == :exists || !seen.add?(entry.path)

            changed?(entry.path)
          end
        end

        def globs_unchanged?(entries)
          entries.none? do |entry|
            listed = Dir.glob(File.join(entry.root, File.dirname(entry.pattern), ""))
            matched = entry.mode == :stat ? Dir.glob(File.join(entry.root, entry.pattern)) : []
            (listed + matched).any? { |path| changed?(path) }
          end
        end

        def changed?(path)
          Cache::FileDigest.ns_of(File.stat(path).ctime) >= @started_ns
        rescue SystemCallError
          false
        end
      end
    end
  end
end
