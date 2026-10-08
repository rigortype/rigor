# frozen_string_literal: true

require "fileutils"
require "securerandom"

require_relative "../incremental_run_slot"
require_relative "../../cache/file_digest"
require_relative "../../cache/incremental_snapshot"

module Rigor
  module Analysis
    module IncrementalRunSlot
      # ADR-45 WD2 (#1507) — whether a run may record its answer at all. Some of a slot's rows are built when the
      # run ENDS rather than when it reads, and each of those must still describe the tree the run analysed: a
      # save that lands while the run reads — an editor's, a `bundle install`'s, a `mkdir` — would otherwise leave
      # the slot vouching for a tree the analysis never saw, and the probe would serve the pre-save answer against
      # the post-save tree.
      #
      # So the session takes a mark before the run reads anything ({.start}) and asks {#admits?} about those rows
      # before it writes. A row recorded as the run read (a plugin's read, a listing it took) needs no guard: a
      # later save leaves it stale, and validation says so.
      #
      # The mark is the filesystem's own clock, read off the change time of a file written for the purpose: a
      # timestamp compared across clocks misses an edit that lands inside a coarse filesystem's tick, and change
      # times (unlike modification times) cannot be set back by `cp -p` or `touch -d`. One clock means one
      # filesystem, so the mark is taken only when the store is on the project's filesystem, and a row the key
      # does not pin refuses the write when it is on any other. Declining to write is always safe; it leaves the
      # next null run on the full path.
      #
      # A filesystem's change times tick coarsely (a millisecond or more on ext4 and tmpfs), so a file saved just
      # before the stamp can carry the stamp's own change time. {#admits?} refuses a change time at or after the
      # mark, since a save after the stamp in the same tick reads the same; taking the first stamp as the mark
      # would therefore refuse every save that landed shortly before the run, and no slot would be written. So the
      # mark is taken on a tick boundary: stamps are written until one carries a later change time than the first,
      # and that later change time is the mark. Everything saved before the run started carries a change time no
      # later than the first stamp, hence before the mark; everything saved after the mark carries at least the
      # mark. The wait is bounded ({TICK_WAIT_LIMIT}); a filesystem that does not tick within it takes no mark,
      # which is the safe answer. A filesystem whose first stamp lands on a whole second (HFS+, FAT, ext3) ticks too
      # coarsely to wait out and takes no mark at once.
      #
      # Where the change time is not the time of the write, the mark says nothing, and the guard takes none or
      # cannot tell: native Windows, where a change time is the creation time, takes no mark; a network or FUSE
      # filesystem (NFS with its attribute cache, virtiofs, sshfs) may report a change time from before a save,
      # which nothing here detects. A clock that steps backwards (an NTP correction) inside the run would date a
      # save before the mark, so {#admits?} takes one more stamp and refuses when it reads earlier than the mark.
      # A step undone before the run ends is not seen.
      class WriteGuard
        STAMP_DIR = "incremental"
        private_constant :STAMP_DIR

        # How long to wait, in seconds, for the filesystem's change time to tick past the first stamp.
        TICK_WAIT_LIMIT = 0.05
        # The pause between stamps.
        TICK_RETRY_DELAY = 0.0005
        private_constant :TICK_RETRY_DELAY

        # Takes the mark, or nil when the slot must not be written: no stamp can be written, it is not on the
        # project's filesystem, or the snapshot fingerprint the run was given no longer describes the tree.
        #
        # The fingerprint is recomputed AFTER the stamp: the caller computed it earlier, and a lockfile or a
        # signature file under the configured or auto-detected `sig/` roots, or a `pre_eval:` file, changed in
        # between would leave the snapshot the run restores keyed by one tree
        # and the run reading another. From the stamp on, the lockfiles are the guard's to watch ({#admits?}), which
        # is also what lets the slot's key, whose only file inputs they are, be computed when the run ends.
        #
        # The mark also records which of the paths an existence row can name are present: the lockfiles, the
        # analysis roots, the `pre_eval:` entries and the signature roots.
        def self.start(configuration:, roots:, cache_root:, fingerprint:)
          return nil if Gem.win_platform?

          started_ns, device = stamp(cache_root)
          return nil if started_ns.nil? || device_of(Dir.pwd) != device
          return nil unless Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: roots) ==
                            fingerprint

          lockfiles = lockfile_paths(configuration)
          named = Array(roots) + configuration.pre_eval + (configuration.signature_paths || ["sig"])
          presence = (lockfiles + named.map { |path| File.absolute_path(path.to_s) }).to_h do |path|
            [path, File.exist?(path)]
          end
          new(started_ns: started_ns, device: device, lockfiles: lockfiles, presence: presence,
              stamp_dir: stamp_dir(cache_root))
        end

        # The mark: the change time and device of the first stamp whose change time is later than that of a
        # stamp taken before it, on the same device; nil when none is written within {TICK_WAIT_LIMIT}.
        def self.stamp(cache_root)
          dir = stamp_dir(cache_root)
          FileUtils.mkdir_p(dir)
          first_ns, device = write_stamp(dir)
          # A change time on a whole second is a filesystem that ticks by the second: waiting for it would burn the
          # whole bound. One that ticks finer lands there once in a billion stamps, and declining is safe.
          return nil if first_ns.nil? || (first_ns % 1_000_000_000).zero?

          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TICK_WAIT_LIMIT
          loop do
            ns, dev = write_stamp(dir)
            return nil if ns.nil? || dev != device
            return [ns, device] if ns > first_ns
            return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep(TICK_RETRY_DELAY)
          end
        rescue SystemCallError, IOError
          nil
        end
        private_class_method :stamp

        def self.stamp_dir(cache_root)
          File.join(cache_root.to_s, STAMP_DIR)
        end
        private_class_method :stamp_dir

        # One stamp's change time and device; the file is removed again.
        def self.write_stamp(dir)
          path = File.join(dir, "run-#{Process.pid}-#{SecureRandom.hex(4)}.stamp")
          File.write(path, "")
          stat = File.stat(path)
          [Cache::FileDigest.ns_of(stat.ctime), stat.dev]
        rescue SystemCallError, IOError
          nil
        ensure
          FileUtils.rm_f(path) if path
        end
        private_class_method :write_stamp

        def self.device_of(path)
          File.stat(path).dev
        rescue SystemCallError
          nil
        end
        private_class_method :device_of

        # Every lockfile the key or the snapshot fingerprint may digest, present or not: a lockfile that appears
        # while the run reads moves the key as surely as one rewritten, and one rewritten and restored digests as it
        # did while the run may have read the other bytes.
        def self.lockfile_paths(configuration)
          configured = [
            [configuration.bundler_lockfile, Environment::LockfileResolver],
            [configuration.rbs_collection_lockfile, Environment::RbsCollectionDiscovery]
          ].filter_map { |path, resolver| resolver.configured_lockfile_path(path) if path }
          (configured + %w[Gemfile.lock rbs_collection.lock.yaml].map { |path| File.absolute_path(path) }).uniq
        end
        private_class_method :lockfile_paths

        def initialize(started_ns:, device:, lockfiles:, presence: {}, stamp_dir: nil)
          @stamp_dir = stamp_dir
          @started_ns = started_ns
          @device = device
          @lockfiles = lockfiles
          @presence = presence
        end

        # True when nothing the guard watches moved since the mark:
        #
        # - no lockfile the key or the fingerprint digests was written, created or removed;
        # - no file `rows` or `pinned` names changed. A content row's file changed if its change time moved. An
        #   existence row asks only whether its path is there, so a path the mark recorded changed if it came or
        #   went, and an editor's lock file created and removed beside it, which moves its directory's change
        #   time, does not count. That needs no clock, so it holds on any filesystem; it cannot see a path that
        #   comes and goes again within the run. Any other existence row falls back to change times: its own when
        #   present, its nearest existing ancestor's when absent;
        # - no directory a glob row lists gained or lost an entry, nor, for a stat-mode glob, did any file it
        #   matches change.
        #
        # A path on another filesystem than the mark refuses the write when it is one of `rows`, and is passed
        # over when it is one of `pinned`: the rows the key pins (the engine's own signature files, a gem's
        # signatures, which the engine slot and the lockfiles identify) live wherever the engine and the gems are
        # installed — a container image's layer, a Nix store — and refusing them would turn the fast path off for
        # every such installation. On the mark's filesystem they are checked like any other row.
        #
        # A content row whose file is gone passes: the row is stale already, and validation says so.
        #
        # @param rows — a {Cache::Descriptor} of the rows the key does not pin
        # @param pinned — a {Cache::Descriptor} of the rows it does
        def admits?(rows, pinned: Cache::Descriptor.new)
          !clock_stepped_back? && @lockfiles.none? { |path| lockfile_changed?(path) } &&
            files_unchanged?(rows.files, strict: true) && globs_unchanged?(rows.globs, strict: true) &&
            files_unchanged?(pinned.files, strict: false) && globs_unchanged?(pinned.globs, strict: false)
        rescue StandardError
          false
        end

        # `descriptor` with every `:stat` row's recording instant no later than the mark. A row recorded as the run
        # read carries the instant the run began, and validation trusts a stat tuple whose mtime is before it. On a
        # coarse clock a save that lands after the read, in the tick the file's mtime already has and with the same
        # size, leaves the tuple unmoved, so it would be trusted. With the instant at the mark, every row whose mtime is
        # at or after the mark is racy, and validation re-hashes it.
        def mark_racy(descriptor)
          Cache::Descriptor.new(
            files: descriptor.files.map { |entry| entry.with_recording_instant_at_most(@started_ns) },
            gems: descriptor.gems, plugins: descriptor.plugins, configs: descriptor.configs,
            dependencies: descriptor.dependencies, globs: descriptor.globs
          )
        end

        private

        # One more stamp: a change time earlier than the mark means the clock stepped back since it was taken, so
        # a save since then may carry a change time the guard reads as before it. A stamp that cannot be written,
        # or lands on another device, cannot vouch for the clock either.
        def clock_stepped_back?
          return false if @stamp_dir.nil?

          ns, device = self.class.__send__(:write_stamp, @stamp_dir)
          ns.nil? || device != @device || ns < @started_ns
        end

        # An existence row and a content row for one path are different questions (the first asks only whether it
        # is there, the second whether it changed), so the row that comes first must not hide the other.
        def files_unchanged?(entries, strict:)
          seen = Set.new
          entries.none? do |entry|
            next false unless seen.add?([entry.path, entry.comparator == :exists])

            if entry.comparator == :exists
              existence_changed?(entry.path, strict: strict)
            else
              changed?(entry.path, strict: strict)
            end
          end
        end

        def globs_unchanged?(entries, strict:)
          entries.none? do |entry|
            listed = Dir.glob(File.join(entry.root, File.dirname(entry.pattern), ""))
            matched = entry.mode == :stat ? Dir.glob(File.join(entry.root, entry.pattern)) : []
            (listed + matched).any? { |path| changed?(path, strict: strict) }
          end
        end

        # A lockfile is read for its bytes: one absent at the mark must still be absent, one present must still be
        # there with its change time before the mark.
        def lockfile_changed?(path)
          return File.exist?(path) unless @presence[path]

          changed?(path, strict: true, missing: true)
        end

        def existence_changed?(path, strict:)
          absolute = File.absolute_path(path)
          return File.exist?(absolute) != @presence[absolute] if @presence.key?(absolute)

          nearest = absolute
          nearest = File.dirname(nearest) until File.exist?(nearest) || File.dirname(nearest) == nearest
          moved?(File.stat(nearest), strict: strict)
        rescue SystemCallError
          true
        end

        def changed?(path, strict:, missing: false)
          moved?(File.stat(path), strict: strict)
        rescue SystemCallError
          missing
        end

        # A change time is comparable with the mark only on the stamp's filesystem.
        def moved?(stat, strict:)
          return strict if stat.dev != @device

          Cache::FileDigest.ns_of(stat.ctime) >= @started_ns
        end
      end
    end
  end
end
