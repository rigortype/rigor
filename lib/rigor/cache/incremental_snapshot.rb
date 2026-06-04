# frozen_string_literal: true

require "fileutils"

module Rigor
  module Cache
    # ADR-46 — disk persistence for the incremental analyzer's per-file
    # state, so a `--incremental` session survives across processes (one
    # `rigor check` invocation reads the prior run's per-file diagnostics +
    # dependency graph, re-analyzes only the changed closure, and serves the
    # rest from disk).
    #
    # Unlike ADR-45's whole-run cache (record-and-validate ONE entry,
    # invalidated by any analyzed-file change), this snapshot is loaded
    # UNCONDITIONALLY when the global fingerprint matches — the per-file
    # digests *inside* it drive the incremental re-analysis decision; they
    # do not gate the load. The fingerprint captures the inputs whose change
    # requires a full rebuild — the resolved configuration, the RBS
    # environment, the engine version — but NOT the analyzed source
    # contents. A fingerprint mismatch (config / gem / version change) drops
    # the snapshot and forces a full re-analysis, the conservative
    # direction.
    #
    # Every operation is fault-tolerant: a missing, unreadable, schema-
    # mismatched, fingerprint-mismatched, or corrupt snapshot loads as nil
    # (→ a cold full run), and a write failure is swallowed (→ the next run
    # is cold). A cache must never break a run (the ADR-45 invariant).
    class IncrementalSnapshot
      # Bump when the on-disk shape changes so stale snapshots are ignored
      # rather than mis-deserialized.
      SCHEMA = 1

      # The persisted per-file state. `cache` maps an analyzed file to its
      # diagnostics, `sources` to the set of files its analysis read from,
      # `digests` to its content digest at analysis time, and `analyzed` is
      # the ordered analyzed-file list.
      Payload = Data.define(:cache, :sources, :digests, :analyzed)

      def initialize(root:)
        @path = File.join(root.to_s, "incremental", "snapshot.bin")
      end

      attr_reader :path

      # The stored {Payload}, or nil when absent / unreadable / schema or
      # fingerprint mismatch / corrupt. Never raises.
      def load(fingerprint:)
        data = Marshal.load(File.binread(@path)) # rubocop:disable Security/MarshalLoad
        return nil unless data.is_a?(Hash) && data[:schema] == SCHEMA && data[:fingerprint] == fingerprint

        Payload.new(
          cache: data[:cache], sources: data[:sources],
          digests: data[:digests], analyzed: data[:analyzed]
        )
      rescue StandardError
        nil
      end

      # Persist `payload` under `fingerprint`. Writes via a temp file +
      # atomic rename so a concurrent reader never sees a half-written
      # snapshot. Returns true on success, false on any failure (never
      # raises).
      def save(fingerprint:, payload:)
        FileUtils.mkdir_p(File.dirname(@path))
        blob = Marshal.dump(
          schema: SCHEMA, fingerprint: fingerprint,
          cache: payload.cache, sources: payload.sources,
          digests: payload.digests, analyzed: payload.analyzed
        )
        tmp = "#{@path}.#{Process.pid}.tmp"
        File.binwrite(tmp, blob)
        File.rename(tmp, @path)
        true
      rescue StandardError
        false
      end
    end
  end
end
