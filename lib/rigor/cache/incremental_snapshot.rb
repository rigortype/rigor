# frozen_string_literal: true

require "fileutils"
require "digest"
require "zlib"

require_relative "engine_source"

module Rigor
  module Cache
    # ADR-46 — disk persistence for the incremental analyzer's per-file state, so a `--incremental` session
    # survives across processes (one `rigor check` invocation reads the prior run's per-file diagnostics +
    # dependency graph, re-analyzes only the changed closure, and serves the rest from disk).
    #
    # Unlike ADR-45's whole-run cache (record-and-validate ONE entry, invalidated by any analyzed-file change),
    # this snapshot is loaded UNCONDITIONALLY when the global fingerprint matches — the per-file digests
    # *inside* it drive the incremental re-analysis decision; they do not gate the load. The fingerprint
    # captures the inputs whose change requires a full rebuild — the resolved configuration, the RBS
    # environment, the engine version and (on a checkout) the engine's own source — but NOT the analyzed
    # source contents. A fingerprint mismatch (config / gem / version / engine change) drops the snapshot and
    # forces a full re-analysis, the conservative direction.
    #
    # An engine change drops the WHOLE snapshot rather than part of it, which is a soundness point before it
    # is a simplicity one: every section here except `digests` is a value the analyzer computed, so a changed
    # engine can move any of it — including the dependency edges, where a new engine recording an edge the old
    # one missed would let a recheck skip the very file that needed re-analysing. Retaining the one
    # engine-independent section would not pay either: `digests` is 2.5% of a 2.5 MB snapshot of this repo,
    # and re-deriving it is a file-digest walk costing ~0.2% of the full run it would be saving.
    #
    # Every operation is fault-tolerant: a missing, unreadable, schema-mismatched, fingerprint-mismatched, or
    # corrupt snapshot loads as nil (→ a cold full run), and a write failure is swallowed (→ the next run is
    # cold). A cache must never break a run (the ADR-45 invariant).
    class IncrementalSnapshot
      # Bump when the on-disk shape changes so stale snapshots are ignored rather than mis-deserialized. 5:
      # the blob is zlib-deflated (ADR-54 WD2 parity with `Store` entries — the snapshot is the one cache
      # artefact that does not go through `Store`); a raw pre-5 blob fails the inflate and loads as nil, the
      # usual fault-tolerant cold-run path. 6: adds the ADR-85 WD2 `seed_bundles` section (per-file discovery
      # contributions with `(node_id, name, fingerprint)` def-node handles); a pre-6 blob mismatches the
      # SCHEMA gate and loads as nil (a clean cold rebuild — no migration). 7: the seed bundle gains a
      # `singleton_def_sources` table (ADR-46 slice 4 extended to class/singleton methods) AND `digests`
      # switches to ADR-87 packed stat entries; a pre-7 blob mismatches the gate and loads as nil (clean cold
      # rebuild). 8: each seed bundle additionally gains a comment-stripped `code_fingerprint` for the B1
      # bundle-equality gate; a pre-8 blob mismatches and loads as nil (clean cold rebuild). 9: adds the ADR-88
      # WD1 `plugin_fact_digest` (a fingerprint of the plugin fact SURFACE — ADR-9 facts, ADR-60 producer
      # values, and `incremental_state_fingerprint` hooks — that a cached diagnostic can depend on but the
      # global fingerprint does not capture); a pre-9 blob mismatches the SCHEMA gate and loads as nil (a clean
      # cold rebuild — no migration). 10: ADR-89 WD1 adds a per-file `declaration_signature` to each seed
      # bundle (the per-def parameter-shape / visibility / ancestry surface the declaration-stability gate
      # compares) and WD2 adds `return_summaries` (per-def observed-key return descriptors + mutation-effect
      # sets the behavioural-stability gate compares); a pre-10 blob mismatches the SCHEMA gate and loads as
      # nil (a clean cold rebuild — no migration). 11: ADR-67 WD6c lift adds `param_table` (the inferred-param
      # seed table the run's diagnostics were computed under, diffed on the next recheck to invalidate a
      # callee whose seeds moved because a caller changed); a pre-11 blob mismatches the SCHEMA gate and
      # loads as nil (a clean cold rebuild — no migration). 12: ADR-103 WD13 / issue #382 adds the effects
      # sidecar — `effect_collections` (the per-file {Rigor::Effects::FileCollection}s a collecting run
      # produced) and the `effects_identity` they were produced under; a pre-12 blob mismatches the SCHEMA
      # gate and loads as nil (a clean cold rebuild — no migration). 13: issue #644 adds `constant_decls`
      # (the per-file constant PUBLICATION CENSUS — `{qualified name => [literal] | :unpublishable}` — whose
      # diff drives the new `constant:` edge's producer) and grows each seed bundle's row grammar by its own
      # `constant_writes` census; a pre-13 blob mismatches the SCHEMA gate and loads as nil (a clean cold
      # rebuild — no migration). 14: issue #707 widens each seed-bundle def row from `[node_id, name,
      # fingerprint]` to `[node_id, name, fingerprint, nesting]`, carrying issue #681's recorded
      # `Module.nesting` so a bundle-served callee resolves its constants under the declaration that owns it
      # instead of a peel of the receiver's name; a pre-14 blob mismatches the SCHEMA gate and loads as nil (a
      # clean cold rebuild — no migration). The bump is what keeps a pre-14 blob REJECTED rather than MISREAD:
      # a three-element row destructures with `nesting` nil, which is indistinguishable from a top-level def,
      # so every unchanged file would silently keep the pre-fix peel. 15: issue #682 gives each seed bundle a
      # `header_nestings` table — the `Module.nesting` each class / module DECLARATION HEADER is written in —
      # so a bundle-served class resolves its superclass and include names in the cref Ruby resolves them in
      # rather than by peeling its own qualified name; a pre-15 blob mismatches the SCHEMA gate and loads as
      # nil (a clean cold rebuild — no migration). Absence here is gradual rather than misread (the resolver
      # falls back to the peel), but a warm run that peels where a cold run does not is exactly the
      # `--verify-incremental` divergence 14 was bumped for.
      # 16: issue #722 residue 1 gives each seed bundle's `superclasses` values a ROOTED MARKER — a leading
      # `::` on an ancestor name the site wrote rooted (`class X < ::Base`, `Class.new(::Parent)`) — so the
      # resolvers anchor it at the top level instead of walking the enclosing nesting. The value stays a
      # String, so a pre-16 blob deserialises cleanly and is exactly why the gate has to reject it: an
      # un-rooted value is indistinguishable from "not rooted", and every unchanged file would keep the
      # pre-fix answer on a warm run while a cold run gave the right one.
      # 17: issue #716 changes what a seed-bundle def row's `nesting` MEANS without changing its shape. A
      # top-level def now records the EMPTY chain (Ruby's `Module.nesting` there is `[]`), so the resolver
      # anchors its constants at the top level instead of peeling the caller's namespace; `nil` narrows to
      # "no chain recorded at all". A pre-17 blob stored `nil` for exactly the top-level defs that now store
      # `[]`, deserialises cleanly, and would send every unchanged file's top-level helper back to the peel
      # on a warm run while a cold run resolved at the top level — the `--verify-incremental` divergence 14
      # was bumped for, in the same table.
      SCHEMA = 17

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
      # Issue #644:
      # `constant_decls` maps a path to that file's constant PUBLICATION CENSUS,
      # `{qualified name => [literal] | :unpublishable}`. The descriptor is what the recheck diffs: a name's
      # published answer is a function of the whole project's write set for it, so a value edit, a write
      # becoming unpublishable, or a second declarer appearing / going away all move the answer without
      # moving the name set.
      # ADR-85 WD2:
      # `seed_bundles` maps an analyzed path to its per-file discovery contribution (plain-data tables +
      # `(node_id, name, fingerprint)` def-node handles + content digest), so a warm recheck rebuilds the
      # cross-file index by folding bundles instead of parsing every file.
      # ADR-88 WD1:
      # `plugin_fact_digest` is a SHA-256 hex fingerprint of the plugin fact surface at the run that wrote the
      # snapshot (or nil for a plugin-free project). A warm recheck recomputes it and, on a mismatch, discards
      # the snapshot and runs a full analysis — the guard for a plugin sig/catalog edit that the global
      # fingerprint cannot see.
      # ADR-89 WD2:
      # `return_summaries` maps a `[path, "Class#method" | "Class.method"]` to the callee's persisted
      # behavioural surface `{ keys:, returns:, effects: }` — the observed `[receiver, arg_types]` call keys
      # (Marshal-clean type tuples), their `describe(:short)` return descriptors, and the content-mutated
      # parameter positions. A recheck re-evaluates a declaration-stable changed callee at these keys and,
      # when every return + the effects are unchanged, skips its symbol dependents.
      # ADR-67 WD6c lift:
      # `param_table` is the `parameter_inference:` seed table (`[class, method, kind] => {param => Type}`)
      # the run that wrote the snapshot seeded its analysis from — `{}` when the gate is off. A recheck
      # recomputes the table fresh (the pre-pass is whole-project by design) and diffs it against this copy;
      # a changed entry invalidates the callee's file and its symbol dependents. The types are Marshal-clean
      # by the session's per-entry filter; a dropped entry re-checks its callee, the conservative direction.
      # ADR-103 WD13 / issue #382 — the effects sidecar, ADR-46's half of "one cache, two identities, one
      # extra slot":
      # `effect_collections` maps an analyzed path to the {Rigor::Effects::FileCollection} that file
      # contributed (`{}` when collection is off), so a recheck re-collects only the changed closure and
      # serves the rest from here. The propagated table is NEVER stored — it is recomputed from the merged
      # whole every run, because a leaf's summary reaches every caller and a stored table would have to be
      # invalidated by all of them.
      # `effects_identity` is {Rigor::Effects::Identity.digest} at the run that wrote them (nil when
      # collection was off). It is a SEPARATE gate from the global `fingerprint`: the `effects:` block is
      # deliberately absent from `Configuration#to_h`, so turning collection on invalidates no diagnostics,
      # and a vocabulary / catalogue / `effects:` change must invalidate the summaries alone.
      Payload = Data.define(:cache, :sources, :digests, :analyzed,
                            :symbol_sources, :ancestry_sources, :symbol_fingerprints,
                            :missing, :class_decls, :constant_decls, :seed_bundles, :plugin_fact_digest,
                            :return_summaries, :param_table,
                            :effect_collections, :effects_identity)

      # The global fingerprint that gates a snapshot load: a digest of the inputs whose change requires a full
      # rebuild — the engine version + schema, the engine's own SOURCE when the version does not pin it, the
      # resolved configuration, the analysis **roots** (the path arguments, e.g. `["lib"]`, NOT the expanded
      # file list — so a snapshot is keyed to an invocation's roots but adding / removing a file under them is
      # handled incrementally by the session, not a full rebuild), the resolved gem set (`Gemfile.lock` /
      # `rbs_collection`), and the project's own RBS (`signature_paths` file contents). Built WITHOUT
      # constructing the RBS environment so the warm path can gate the load cheaply, before the costly env
      # build. The `--verify-incremental` gate is the safety net for any under-capture (it would surface as an
      # incremental-vs-full mismatch). Returns nil on any error → the caller falls back to a non-persisted run.
      #
      # Issue #285, wired here by #289 — every value in this snapshot is something the ANALYZER computed, so
      # `Rigor::VERSION` alone is not enough to identify what produced it. A version pins the engine's bytes
      # for a RubyGems install and for nothing else, so on a checkout a warm recheck served diagnostics a
      # pre-edit analyzer had computed: editing `lib/rigor/inference/*.rb` moved no ANALYZED file, the changed
      # set came back empty, and 357 unchanged files replayed their old answers.
      # {EngineSource.process_identity} closes it, and answers nil for a version-pinned tree — which adds no
      # part, so a released gem's fingerprint is byte-identical to the pre-#289 one and its warm snapshots
      # survive the upgrade untouched.
      def self.fingerprint(configuration:, roots:)
        parts = [
          "engine:#{Rigor::VERSION}:#{SCHEMA}",
          "config:#{Digest::SHA256.hexdigest(Marshal.dump(configuration.to_h))}",
          "roots:#{Array(roots).map(&:to_s).sort.join("\n")}",
          "gems:#{digest_file_if_present('Gemfile.lock')}",
          "rbs_collection:#{digest_file_if_present('rbs_collection.lock.yaml')}",
          "sig:#{digest_signature_paths(configuration.signature_paths)}"
        ]
        identity = EngineSource.process_identity
        parts << "engine-source:#{identity}" if identity
        Digest::SHA256.hexdigest(parts.join("\x00"))
      rescue StandardError
        # {EngineSource::Unavailable} lands here too, and nil is the answer it requires rather than one it
        # merely tolerates: an engine we cannot identify must DISABLE the snapshot, never fall back to the
        # version-only key that is the blind spot above. Nil does disable it on both sides —
        # {Analysis::IncrementalSession} guards the load AND the save on the fingerprint, so nothing stale is
        # read and no nil-keyed blob is written for the next equally-unidentifiable run to match against.
        nil
      end

      def self.digest_file_if_present(path)
        File.file?(path) ? Digest::SHA256.file(path).hexdigest : "absent"
      end
      private_class_method :digest_file_if_present

      # Content-digest every `.rbs` under the configured signature paths (sorted for determinism) so a project
      # RBS edit invalidates the snapshot. Sig trees are small; content (not mtime) keeps it stable across
      # checkouts.
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

      # The stored {Payload}, or nil when absent / unreadable / schema or fingerprint mismatch / corrupt.
      # Never raises.
      def load(fingerprint:)
        data = read_data
        return nil unless data && data[:fingerprint] == fingerprint

        payload_from(data)
      end

      # Issue #134 slice 2 — the same load against SEVERAL acceptable fingerprints, reading the blob once.
      # A reader that did not itself write the snapshot cannot know which analysis ROOTS it was written under
      # (`rigor check --incremental lib` and a bare `rigor check --incremental` produce different fingerprints
      # for the same project), and `#load` would have to re-inflate + re-unmarshal the whole blob per candidate.
      # The fingerprint that matched is returned alongside the payload so the caller can mix it into ITS own
      # cache key — the snapshot's identity is exactly what "these dependency edges came from that world" means.
      #
      # @param fingerprints [Array<String>] candidates, most-specific first.
      # @return [Array(String, Payload), nil] `[matched fingerprint, payload]`, or nil on any miss.
      def load_any(fingerprints:)
        data = read_data
        return nil if data.nil?

        matched = Array(fingerprints).compact.find { |candidate| data[:fingerprint] == candidate }
        return nil if matched.nil?

        [matched, payload_from(data)]
      end

      # The raw stored Hash when it is present, readable, and schema-current; nil otherwise. Never raises —
      # a missing, corrupt, or stale-schema snapshot is a cold run, not an error (the ADR-45 invariant).
      def read_data
        data = Marshal.load(Zlib::Inflate.inflate(File.binread(@path))) # rubocop:disable Security/MarshalLoad
        data.is_a?(Hash) && data[:schema] == SCHEMA ? data : nil
      rescue StandardError
        nil
      end
      private :read_data

      def payload_from(data)
        Payload.new(
          cache: data[:cache], sources: data[:sources],
          digests: data[:digests], analyzed: data[:analyzed],
          symbol_sources: data[:symbol_sources] || {},
          ancestry_sources: data[:ancestry_sources] || {},
          symbol_fingerprints: data[:symbol_fingerprints] || {},
          missing: data[:missing] || {},
          class_decls: data[:class_decls] || {},
          constant_decls: data[:constant_decls] || {},
          seed_bundles: data[:seed_bundles] || {},
          plugin_fact_digest: data[:plugin_fact_digest],
          return_summaries: data[:return_summaries] || {},
          param_table: data[:param_table] || {},
          effect_collections: data[:effect_collections] || {},
          effects_identity: data[:effects_identity]
        )
      end
      private :payload_from

      # Persist `payload` under `fingerprint`. Writes via a temp file + atomic rename so a concurrent reader
      # never sees a half-written snapshot. Returns true on success, false on any failure (never raises).
      def save(fingerprint:, payload:)
        FileUtils.mkdir_p(File.dirname(@path))
        raw = Marshal.dump(
          schema: SCHEMA, fingerprint: fingerprint,
          cache: payload.cache, sources: payload.sources,
          digests: payload.digests, analyzed: payload.analyzed,
          symbol_sources: payload.symbol_sources,
          ancestry_sources: payload.ancestry_sources,
          symbol_fingerprints: payload.symbol_fingerprints,
          missing: payload.missing,
          class_decls: payload.class_decls,
          constant_decls: payload.constant_decls,
          seed_bundles: payload.seed_bundles,
          plugin_fact_digest: payload.plugin_fact_digest,
          return_summaries: payload.return_summaries,
          param_table: payload.param_table,
          effect_collections: payload.effect_collections,
          effects_identity: payload.effects_identity
        )
        blob = Zlib::Deflate.deflate(raw)
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
