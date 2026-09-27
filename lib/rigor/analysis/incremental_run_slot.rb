# frozen_string_literal: true

require_relative "diagnostic"
require_relative "path_expansion"
require_relative "result"
require_relative "run_cache_key"
require_relative "../cache/descriptor"
require_relative "../cache/file_digest"
require_relative "../cache/store"

module Rigor
  module Analysis
    # ADR-45 WD2 (#1507) — the run-result slot `rigor check --incremental` writes, and the engine-free probe that
    # serves a null run from it. The writer is {IncrementalSession#run_incremental}; the reader is the CLI, before
    # it loads the inference engine. Both go through this module, so the key, the producer id and the stored shape
    # have one definition.
    #
    # It is ADR-45's record-and-validate slot with a second writer. The value is the diagnostics the session's run
    # printed (before the baseline filter, which the CLI applies to every answer), and the dependency descriptor
    # validates everything that answer was computed from:
    #
    # - one `:stat` row per analysed file, carrying the digest the SESSION holds for it — the bytes its cached rows
    #   were computed from — rather than a re-digest taken after the run;
    # - the rows the run re-read itself ({Runner#incremental_slot_rows}' `run` half);
    # - the chain the {Entry} carries forward: the signature tree the last full run recorded, and the plugin reads
    #   each file's analysis made, kept per file so a recheck that serves a file from cache still validates what
    #   that file's analysis read ({IncrementalSession#write_run_slot}).
    #
    # Keyed apart from the plain run's `analysis.run-diagnostics` by its own producer id, so neither probe can ever
    # read the other's entry, and an incremental defect cannot leak into a default run.
    #
    # The key is the one {RunCacheProbe} reconstructs from configuration alone — the library list without a
    # `rbs.virtual_rbs` slot, and no `template-units` slot. The session writes no slot for a project whose plugins
    # claim template globs, whose `template-units` slot this key leaves out; the ADR-87 probe misses on such a
    # project for the same reason. A virtual RBS buffer is a function of an analysed file's bytes (a row) and of
    # the synthesising plugin's identity and configuration (the key's `configuration`, lockfile and engine slots),
    # so it needs no slot of its own here.
    #
    # `explain:` is always false: the session's runners never set it (#1533), and the CLI declines the probe under
    # `--explain`.
    module IncrementalRunSlot
      module_function

      PRODUCER_ID = "analysis.incremental-run-diagnostics"

      # One live generation per analysed-path set, as for the plain slot. A writer that moves the path set discards
      # the entry it carried from (see {IncrementalSession}), so the churn a file addition makes is bounded without
      # a compaction pass — the incremental path never runs one.
      GENERATION_CAP = RunCacheKey::GENERATION_CAP

      # The stored value. `signature` (a {Cache::Descriptor}) and `reads` (`{path => Cache::Descriptor}`) are the
      # chain the next writer carries forward, kept apart from the rest of the dependency descriptor so it knows
      # which rows are which; their entries are the same objects the descriptor holds, so `Marshal` writes them
      # once. `snapshot` is the identity of the incremental snapshot file the writing run left behind, which the
      # next writer compares against the one it restored before trusting the chain.
      Entry = Data.define(:diagnostics, :signature, :reads, :snapshot)

      # What a probe hit hands the CLI: the answer, and the analysed-file count its banner reports.
      Hit = Data.define(:result, :file_count)

      def key(configuration:, files:)
        RunCacheKey.descriptor(
          configuration: configuration, files: files, explain: false,
          rbs_config_entries: RunCacheKey.libraries_config_entries(configuration)
        )
      end

      # The engine-free probe. Returns a {Hit} when the slot for this run's analysed-path set validates, or nil to
      # decline: a miss, a stale row, an unreadable entry, a project with effect collection on (see below), or any
      # failure at all — declining hands the run to the full path, which is always safe.
      #
      # Effect collection is declined here and never written by the session. Its configuration (`effects:`) is
      # deliberately absent from `Configuration#to_h` and so from the key, and two of its rows are judged each run
      # from state no engine-free path can rebuild (the plain probe's `envelope_lane_live?`, #428). With it off,
      # the only effect row a run can print is `effect.annotations-unchecked`, which is a function of the
      # signature tree and the analysed files' annotations — both validated rows — so it is served as stored.
      def serve(configuration:, cache_root:, paths:)
        return nil if configuration.effects_enabled?

        files = PathExpansion.ruby_files(paths, configuration.exclude_patterns)
        slot_key = key(configuration: configuration, files: files)
        return nil if slot_key.nil?

        entry = validated_entry(configuration, cache_root, slot_key)
        return nil unless entry.is_a?(Entry) && entry.diagnostics.is_a?(Array)

        Hit.new(result: Result.new(diagnostics: entry.diagnostics, stats: nil), file_count: files.size)
      rescue StandardError
        nil
      end

      # The previous slot's {Entry}, read WITHOUT validating it: it is stale by construction, since the run that
      # is asking changed something. nil when there is no such slot, or it is not an {Entry} — the writer then
      # skips its own write rather than guess what the files it served from cache depended on.
      def previous_entry(store:, configuration:, files:)
        slot_key = key(configuration: configuration, files: files)
        return nil if slot_key.nil?

        entry = store.peek_unvalidated(producer_id: PRODUCER_ID, key_descriptor: slot_key)
        return nil unless entry.is_a?(Entry) && entry.signature.is_a?(Cache::Descriptor) && entry.reads.is_a?(Hash)

        entry
      end

      # Writes the slot for `files`. `dependencies` is the whole descriptor to validate; `signature` and `reads`
      # the chain within it. Returns whether it wrote.
      def write(store:, configuration:, files:, diagnostics:, dependencies:, signature:, reads:, snapshot:) # rubocop:disable Metrics/ParameterLists
        slot_key = key(configuration: configuration, files: files)
        return false if slot_key.nil?

        store.store_validated(
          producer_id: PRODUCER_ID, key_descriptor: slot_key, generation_cap: GENERATION_CAP,
          value: Entry.new(diagnostics: diagnostics, signature: signature, reads: reads, snapshot: snapshot),
          dependencies: dependencies
        )
      end

      def discard(store:, configuration:, files:)
        slot_key = key(configuration: configuration, files: files)
        slot_key && store.discard(producer_id: PRODUCER_ID, key_descriptor: slot_key)
      end

      # Validation runs in its own per-run digest scope, with the configuration's `cache.validation` mode, exactly
      # as the plain probe's does.
      def validated_entry(configuration, cache_root, slot_key)
        store = Cache::Store.new(root: cache_root, max_bytes: configuration.cache_max_bytes)
        Cache::FileDigest.with_run(strict: configuration.cache_validation_strict?) do
          store.peek_validated(producer_id: PRODUCER_ID, key_descriptor: slot_key)
        end
      end
      private_class_method :validated_entry
    end
  end
end
