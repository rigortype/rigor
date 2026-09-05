# frozen_string_literal: true

require "digest"

module Rigor
  module Cache
    # Per-run content-digest memo AND the ADR-87 stat-then-digest freshness choke point. Within a single
    # `Rigor::Analysis::Runner#run`, the same absolute path is SHA-256'd at most once — across every descriptor
    # that digests files: the run-diagnostics dependency descriptor ({Runner#analyzed_file_entries}), the
    # ADR-45 {Descriptor#fresh?} validation of that descriptor, the RBS signature tree
    # ({RbsDescriptor.file_entries}), and every plugin producer's `watch:`-glob validation
    # ({Descriptor::GlobEntry}). Those sets overlap heavily (an analyzed file is often also inside a plugin's
    # watch glob; the RBS tree is digested by both the runner and the RBS producers), so the memo removes the
    # redundant re-hashing that dominates warm-hit validation.
    #
    # ADR-87 WD1 layers a stat tier ON TOP of the memo: a `:stat` {Descriptor::FileEntry} packs a
    # `(digest, size, mtime_ns, ctime_ns, inode)` tuple plus the run's recording instant, and {.stat_fresh?}
    # validates it by stat-ing the file first and only falling back to {.hexdigest} (this memo) when the tuple
    # moved or the racy window fires. On a true null build an unchanged file is a single `File::Stat` call and
    # zero SHA-256 bytes. The SHA-256 digest remains the sole change AUTHORITY — the stat tier only decides
    # whether the digest needs recomputing.
    #
    # Soundness: the memo + recording-instant + strict flag are process-local (thread-locals, so Ractor-safe
    # and never crossing a fork boundary), never persisted to disk, and scoped to exactly one run via
    # {.with_run} (which installs a fresh table and restores the previous one on exit — a second run, or a run
    # that re-reads a file the user edited between runs, gets a clean table). Within a single run the analyzer
    # already assumes the filesystem is stable — {Descriptor#fresh?} validates the whole dependency set against
    # the live tree in one pass and never re-checks mid-run — so caching a coherent per-run snapshot changes
    # nothing about what a run observes. Outside a run scope (no active table) every call digests directly,
    # identical to a bare `Digest::SHA256.file`.
    module FileDigest
      MEMO_KEY = :rigor_cache_file_digest_memo
      STAT_KEY = :rigor_cache_file_stat_memo
      INSTANT_KEY = :rigor_cache_recording_instant
      STRICT_KEY = :rigor_cache_strict_validation
      private_constant :MEMO_KEY, :STAT_KEY, :INSTANT_KEY, :STRICT_KEY

      # Set in the environment to force the strict digest-always validation path for a single run, regardless
      # of the `cache.validation` config setting (the env wins). The escape hatch for a filesystem whose stat
      # tuples cannot be trusted (a coarse-timestamp mount, a restored-from-backup tree).
      STRICT_ENV = "RIGOR_STRICT_VALIDATION"

      # Runs `block` with a fresh per-run digest table installed, restoring whatever table was active before
      # (nil on the normal top-level run; a parent table only if a run were somehow nested). Always restores,
      # even on a raise, so a failed run never leaks its table into the next one. The recording instant is
      # captured at run start — a file whose recorded mtime is not strictly older than it is treated as racy
      # (always re-hashed), catching a file edited during the analysis window. `strict:` forces the
      # digest-always path for `cache.validation: digest`.
      def self.with_run(strict: false)
        previous_memo = Thread.current[MEMO_KEY]
        previous_stat = Thread.current[STAT_KEY]
        previous_instant = Thread.current[INSTANT_KEY]
        previous_strict = Thread.current[STRICT_KEY]
        Thread.current[MEMO_KEY] = {}
        Thread.current[STAT_KEY] = {}
        Thread.current[INSTANT_KEY] = now_ns
        Thread.current[STRICT_KEY] = strict
        yield
      ensure
        Thread.current[MEMO_KEY] = previous_memo
        Thread.current[STAT_KEY] = previous_stat
        Thread.current[INSTANT_KEY] = previous_instant
        Thread.current[STRICT_KEY] = previous_strict
      end

      # The SHA-256 hex digest of `path`'s current content. Served from the active per-run table when one is
      # installed (computing + storing it on first request for that path), otherwise computed directly. A
      # read failure (missing / unreadable file) propagates exactly as `Digest::SHA256.file` would and is NOT
      # memoised, so a caller's own rescue path is unchanged.
      def self.hexdigest(path)
        memo = Thread.current[MEMO_KEY]
        return Digest::SHA256.file(path).hexdigest if memo.nil?

        memo[path] ||= Digest::SHA256.file(path).hexdigest
      end

      # @rbs return: bool --
      #   Whether digest-always validation is forced for this run. The env var wins over the run-scoped config flag so
      #   an operator can bypass the stat tier without editing `.rigor.yml`.
      def self.strict_validation?
        return true if ENV[STRICT_ENV] == "1"

        Thread.current[STRICT_KEY] == true
      end

      # ADR-87 WD1 — packs the `:stat` FileEntry value: `"<digest> <size> <mtime_ns> <ctime_ns> <inode>
      # <recording_instant_ns>"`. The digest is supplied by the caller (already computed via {.hexdigest} or
      # from in-memory content). Returns nil when the file cannot be stat-ed (a race between the digest and the
      # stat), so the caller can fall back to a plain `:digest` entry.
      def self.pack_stat(path, digest)
        st = File.stat(path)
        "#{digest} #{st.size} #{ns(st.mtime)} #{ns(st.ctime)} #{st.ino} #{recording_instant_ns}"
      rescue SystemCallError
        nil
      end

      # ADR-87 WD1 — validates a `:stat` FileEntry value against the live filesystem. Stats the file first;
      # when the `(size, mtime_ns, ctime_ns, inode)` tuple is unchanged AND the entry is not racy, the file is
      # fresh with zero bytes hashed. When the tuple moved or the entry is racy, the recorded digest is the
      # authority: the file is re-hashed and fresh iff the digest still matches (a touch — a moved stat over
      # identical content — therefore validates as fresh). Any stat failure (missing / unreadable file) raises
      # and the caller reads it as stale. In strict mode the stat tier is skipped entirely.
      def self.stat_fresh?(path, packed)
        parsed = parse_stat(packed)
        return false if parsed.nil?

        digest = parsed[0]
        return hexdigest(path) == digest if strict_validation?

        st = validation_stat(path)
        return true if !racy?(parsed) && tuple_matches?(st, parsed)

        hexdigest(path) == digest
      end

      # The VALIDATION-side stat, served from the per-run table when one is installed — a collecting run
      # validates the effects entry and the diagnostics entry against the same ~thousands-of-files
      # dependency descriptor, and the second pass is pure repetition under the run's own stable-filesystem
      # premise (see the module doc). The RECORDING side ({.pack_stat}) deliberately keeps its direct
      # `File.stat`: it packs the tuple a *future* run validates, after the content was read, and must
      # describe that moment rather than an earlier probe's. A stat failure propagates un-memoised, exactly
      # as {.hexdigest} treats a read failure.
      def self.validation_stat(path)
        memo = Thread.current[STAT_KEY]
        return File.stat(path) if memo.nil?

        memo[path] ||= File.stat(path)
      end

      def self.recording_instant_ns
        Thread.current[INSTANT_KEY] || now_ns
      end

      # value layout: [digest, size, mtime_ns, ctime_ns, inode, recording_instant_ns]
      def self.parse_stat(packed)
        parts = packed.to_s.split
        return nil unless parts.size == 6

        [parts[0], *parts[1..].map { |n| Integer(n, 10) }]
      rescue ArgumentError
        nil
      end
      private_class_method :parse_stat

      def self.tuple_matches?(stat, parsed)
        stat.size == parsed[1] && ns(stat.mtime) == parsed[2] &&
          ns(stat.ctime) == parsed[3] && stat.ino == parsed[4]
      end
      private_class_method :tuple_matches?

      # An entry is racy when its recorded mtime is not strictly older than the run's recording instant — the
      # file was (or may have been) modified within the recording window, so its stat tuple cannot be trusted
      # to have settled. Such an entry always re-hashes. On a nanosecond-resolution filesystem this fires only
      # for a file edited during the analysis run itself.
      def self.racy?(parsed)
        parsed[2] >= parsed[5]
      end
      private_class_method :racy?

      # Full-nanosecond integer for a `Time` (from `File::Stat#mtime`/`#ctime`). Public so {GlobEntry} packs
      # its per-file rows with the identical resolution the FileEntry tuple uses.
      def self.ns_of(time)
        (time.tv_sec * 1_000_000_000) + time.tv_nsec
      end

      def self.ns(time)
        ns_of(time)
      end
      private_class_method :ns

      def self.now_ns
        Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      end
      private_class_method :now_ns
    end
  end
end
