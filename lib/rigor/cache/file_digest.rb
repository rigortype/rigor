# frozen_string_literal: true

require "digest"

module Rigor
  module Cache
    # Per-run content-digest memo. Within a single `Rigor::Analysis::Runner#run`, the same absolute path is
    # SHA-256'd at most once — across every descriptor that digests files: the run-diagnostics dependency
    # descriptor ({Runner#analyzed_file_entries}), the ADR-45 {Descriptor#fresh?} validation of that
    # descriptor, the RBS signature tree ({RbsDescriptor.file_entries}), and every plugin producer's
    # `watch:`-glob validation ({Descriptor::GlobEntry}). Those sets overlap heavily (an analyzed file is
    # often also inside a plugin's watch glob; the RBS tree is digested by both the runner and the RBS
    # producers), so the memo removes the redundant re-hashing that dominates warm-hit validation.
    #
    # Soundness: the memo is process-local (a thread-local, so it is Ractor-safe and never crosses a fork
    # boundary), never persisted to disk, and scoped to exactly one run via {.with_run} (which installs a
    # fresh table and restores the previous one on exit — a second run, or a run that re-reads a file the
    # user edited between runs, gets a clean table). Within a single run the analyzer already assumes the
    # filesystem is stable — {Descriptor#fresh?} validates the whole dependency set against the live tree in
    # one pass and never re-checks mid-run — so caching a coherent per-run snapshot changes nothing about
    # what a run observes. Outside a run scope (no active table) every call digests directly, identical to a
    # bare `Digest::SHA256.file`.
    module FileDigest
      MEMO_KEY = :rigor_cache_file_digest_memo
      private_constant :MEMO_KEY

      # Runs `block` with a fresh per-run digest table installed, restoring whatever table was active before
      # (nil on the normal top-level run; a parent table only if a run were somehow nested). Always restores,
      # even on a raise, so a failed run never leaks its table into the next one.
      def self.with_run
        previous = Thread.current[MEMO_KEY]
        Thread.current[MEMO_KEY] = {}
        yield
      ensure
        Thread.current[MEMO_KEY] = previous
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
    end
  end
end
