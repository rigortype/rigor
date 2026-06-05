# frozen_string_literal: true

require "fileutils"
require "digest"

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
      SCHEMA = 4

      # The persisted per-file state.
      # `cache` maps an analyzed file to its diagnostics.
      # `sources` maps a consumer to the Set of source files it read from.
      # `digests` maps a file to its content digest at analysis time.
      # `analyzed` is the ordered analyzed-file list.
      # ADR-46 slice 4:
      # `symbol_sources` maps a consumer to { source_path → Set<"ClassName#method"> }.
      # `ancestry_sources` maps a consumer to Set<source_path> (class-ancestry deps).
      # `symbol_fingerprints` maps a path to { "ClassName#method" => sha256_hex }.
      # ADR-46 slice 3:
      # `missing` maps a consumer to Set<"kind:name"> it looked up and missed.
      # `class_decls` maps a path to Set<qualified class name> it declares.
      Payload = Data.define(:cache, :sources, :digests, :analyzed,
                            :symbol_sources, :ancestry_sources, :symbol_fingerprints,
                            :missing, :class_decls)

      # The global fingerprint that gates a snapshot load: a digest of the
      # inputs whose change requires a full rebuild — the engine version +
      # schema, the resolved configuration, the analyzed-file SET (adding /
      # removing a file is a structural change handled by a full rebuild
      # here), the resolved gem set (`Gemfile.lock` / `rbs_collection`), and
      # the project's own RBS (`signature_paths` file contents). Built
      # WITHOUT constructing the RBS environment so the warm path can gate
      # the load cheaply, before the costly env build. The
      # `--verify-incremental` gate is the safety net for any under-capture
      # (it would surface as an incremental-vs-full mismatch). Returns nil
      # on any error → the caller falls back to a non-persisted run.
      def self.fingerprint(configuration:, files:)
        parts = [
          "engine:#{Rigor::VERSION}:#{SCHEMA}",
          "config:#{Digest::SHA256.hexdigest(Marshal.dump(configuration.to_h))}",
          "paths:#{files.map(&:to_s).sort.join("\n")}",
          "gems:#{digest_file_if_present('Gemfile.lock')}",
          "rbs_collection:#{digest_file_if_present('rbs_collection.lock.yaml')}",
          "sig:#{digest_signature_paths(configuration.signature_paths)}"
        ]
        Digest::SHA256.hexdigest(parts.join("\x00"))
      rescue StandardError
        nil
      end

      def self.digest_file_if_present(path)
        File.file?(path) ? Digest::SHA256.file(path).hexdigest : "absent"
      end
      private_class_method :digest_file_if_present

      # Content-digest every `.rbs` under the configured signature paths
      # (sorted for determinism) so a project RBS edit invalidates the
      # snapshot. Sig trees are small; content (not mtime) keeps it stable
      # across checkouts.
      def self.digest_signature_paths(signature_paths)
        globbed = Array(signature_paths).flat_map do |entry|
          File.directory?(entry) ? Dir.glob(File.join(entry, "**", "*.rbs")) : [entry]
        end
        files = globbed.select { |path| File.file?(path) }.sort
        digest = Digest::SHA256.new
        files.each { |path| digest << path << "\0" << Digest::SHA256.file(path).hexdigest << "\0" }
        digest.hexdigest
      end
      private_class_method :digest_signature_paths

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
          digests: data[:digests], analyzed: data[:analyzed],
          symbol_sources: data[:symbol_sources] || {},
          ancestry_sources: data[:ancestry_sources] || {},
          symbol_fingerprints: data[:symbol_fingerprints] || {},
          missing: data[:missing] || {},
          class_decls: data[:class_decls] || {}
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
          digests: payload.digests, analyzed: payload.analyzed,
          symbol_sources: payload.symbol_sources,
          ancestry_sources: payload.ancestry_sources,
          symbol_fingerprints: payload.symbol_fingerprints,
          missing: payload.missing,
          class_decls: payload.class_decls
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
