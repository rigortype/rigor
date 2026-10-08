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
    # - the rows the run re-read itself ({Runner#incremental_slot_rows}' `observed` and `derived` rows);
    # - the chain the {Entry} carries forward: the rows the last full run recorded for the inputs the incremental
    #   path does not re-derive on a recheck, and the plugin reads credited to each file's analysis
    #   ({IncrementalSession#write_run_slot}).
    #
    # A hit is at least as careful as the full incremental path — where that path would notice a change, a row
    # notices it first — but it is not a cold run: a stale answer that path serves for a read reaching a file
    # through a plugin's memo (#1553) the probe may serve too. ADR-45 WD2 states the guarantee.
    #
    # Kept apart from the plain run's `analysis.run-diagnostics` by its own producer id and by the roots entry its
    # key adds, either enough alone, so neither probe can ever read the other's entry, and an incremental defect
    # cannot leak into a default run.
    #
    # The key is the one {RunCacheProbe} reconstructs from configuration alone — the library list without a
    # `rbs.virtual_rbs` slot, and no `template-units` slot — plus the analysis roots ({Target}). Neither left-out
    # slot is needed. A virtual RBS buffer is a function of an analysed file's bytes (a row) and of the
    # synthesising plugin's identity and configuration (the key's `configuration`, lockfile and engine slots). A
    # template unit is a function of its template's bytes and of what its transform read (rows) and of the
    # plugin's identity and the engine's (key slots), so a project whose plugins claim template globs is served
    # too. The ADR-87 probe misses on one: the plain slot's key carries the `template-units` slot.
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

      # The stored value. `baseline` and `pinned` (each a {Cache::Descriptor}) and `reads` (`{path =>
      # Cache::Descriptor}`) are the chain the next writer carries forward, kept apart from the rest of the
      # dependency descriptor so it knows which rows are which; their entries are the same objects the descriptor
      # holds, so `Marshal` writes them once. `baseline` and `pinned` hold the rows the last full run recorded for
      # inputs the incremental path does not re-derive on a recheck (the signature tree, the
      # discovered-not-analysed files, the `pre_eval:` files outside the analysed set), `pinned` the signature
      # files the key identifies already ({Runner::BaselineRows}); `reads` the plugin reads credited to each
      # analysed file. `snapshot` is the identity of
      # the incremental snapshot file the writing run left behind, which the next writer compares against the one
      # it restored before trusting the chain. `roots` are the analysis roots as the run was given them
      # ({.as_written}): the key holds them as a set of paths, and the probe serves the entry only to a run that
      # names them the same way, in the same order.
      Entry = Data.define(:diagnostics, :roots, :baseline, :pinned, :reads, :snapshot)

      # What a slot is keyed by: the analysed-path set and the analysis roots the run was given. The roots are
      # not implied by the files — `rigor check --incremental lib extra` with `extra` missing analyses the same
      # files as `rigor check --incremental lib`, and only the first reports `extra` as missing.
      Target = Data.define(:files, :roots)

      # What a probe hit hands the CLI: the answer, and the analysed-file count its banner reports.
      Hit = Data.define(:result, :file_count)

      def key(configuration:, target:)
        base = RunCacheKey.descriptor(
          configuration: configuration, files: target.files, explain: false,
          rbs_config_entries: RunCacheKey.libraries_config_entries(configuration)
        )
        return nil if base.nil?

        roots = RunCacheKey.config_entry("incremental.roots", normalize_roots(target.roots).sort.join("\n"))
        Cache::Descriptor.new(gems: base.gems, configs: base.configs + [roots])
      end

      # The roots as absolute paths, which the KEY holds sorted: `lib`, `./lib` and `lib/` are one root there. A
      # run that reorders its roots still finds the previous slot's chain (the snapshot fingerprint sorts them
      # too), and one that respells them replaces the slot rather than adding one beside it.
      def normalize_roots(roots)
        Array(roots).map { |root| File.absolute_path(root.to_s) }
      end

      # The roots as the run was given them, which {Entry#roots} holds and {.serve} compares. A missing root is
      # reported as written (`./extra: no such file or directory`), and `a b` lists `a`'s files before `b`'s, so
      # neither a respelling nor a reordering may be served another's answer.
      def as_written(roots)
        Array(roots).map(&:to_s)
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
        slot_key = key(configuration: configuration, target: Target.new(files: files, roots: paths))
        return nil if slot_key.nil?

        entry = validated_entry(configuration, cache_root, slot_key)
        return nil unless entry.is_a?(Entry) && entry.diagnostics.is_a?(Array)
        return nil unless entry.roots == as_written(paths)

        Hit.new(result: Result.new(diagnostics: entry.diagnostics, stats: nil), file_count: files.size)
      rescue StandardError
        nil
      end

      # The previous slot's {Entry}, read WITHOUT validating it: it is stale by construction, since the run that
      # is asking changed something. nil when there is no such slot, or it is not an {Entry} — the writer then
      # skips its own write rather than guess what the files it served from cache depended on.
      def previous_entry(store:, configuration:, target:)
        slot_key = key(configuration: configuration, target: target)
        return nil if slot_key.nil?

        entry = store.peek_unvalidated(producer_id: PRODUCER_ID, key_descriptor: slot_key)
        return nil unless entry.is_a?(Entry) && entry.reads.is_a?(Hash)
        return nil unless entry.baseline.is_a?(Cache::Descriptor) && entry.pinned.is_a?(Cache::Descriptor)

        entry
      end

      # Writes `entry` as the slot for `target`, validated by `dependencies` (the whole descriptor, of which the
      # entry's chain is a part). Returns whether it wrote.
      def write(store:, configuration:, target:, entry:, dependencies:)
        slot_key = key(configuration: configuration, target: target)
        return false if slot_key.nil?

        store.store_validated(
          producer_id: PRODUCER_ID, key_descriptor: slot_key, generation_cap: GENERATION_CAP,
          value: entry, dependencies: dependencies
        )
      end

      def discard(store:, configuration:, target:)
        slot_key = key(configuration: configuration, target: target)
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
