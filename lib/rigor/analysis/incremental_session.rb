# frozen_string_literal: true

require "digest"
require_relative "incremental"
require_relative "incremental_run_slot"
require_relative "incremental_run_slot/write_guard"
require_relative "plugin_fact_fingerprint"
require_relative "run_disclosure_ledger"
require_relative "source_rbs_gate"
require_relative "../cache/file_digest"
require_relative "../cache/incremental_snapshot"
require_relative "../effects/file_collection"
require_relative "../effects/identity"
require_relative "../effects/propagator"
require_relative "../inference/scope_indexer"

module Rigor
  module Analysis
    # ADR-46 slice 2 — the in-memory incremental orchestrator that composes the recorded dependency graph
    # ({Runner#file_dependents}), the affected closure ({Incremental.affected}), and the subset-analysis hook
    # ({Runner} `analyze_only:`) into a working incremental re-check.
    #
    # `#baseline` runs a full analysis with dependency recording and keeps, per analyzed file, its
    # diagnostics (the cache), its content digest, and the per-file source set (to maintain the dependents
    # index across rounds). `#recheck` digests the files again, computes the changed set ΔF, re-analyzes
    # only `ΔF ∪ dependents[ΔF]`, and serves every other analyzed file from the cache — the body tier.
    #
    # The invariant the verify harness (and the spec) assert: `#recheck`'s merged diagnostics are
    # byte-identical to a full `--no-cache` re-analysis of the edited tree, in the same order (#1524; the gate
    # itself compares sorted sets). This is the `--verify-incremental` acceptance gate, here without disk
    # persistence or CLI wiring (the cache is in-process). It models the body tier only: an edit that adds /
    # removes / moves a *file* is outside the analyzed set it maintains and falls to a fresh {#baseline} (the
    # structural tier is a later slice).
    # The class-length budget is relaxed: this is one cohesive orchestrator of the incremental state
    # (per-file diagnostics cache, the file-level / symbol-level / negative dependency graphs, and the ADR-85
    # seed bundles), clearer read together than split across micro-classes that would all share the same ivars.
    class IncrementalSession # rubocop:disable Metrics/ClassLength
      # The outcome of a {#recheck}: the merged diagnostics plus the file sets, so a caller (or the verify
      # gate) can report what was re-analyzed versus served from cache. `added` / `removed` carry the
      # structural delta so {#run_incremental} (ADR-87 WD3) can recognise a zero-change recheck and skip the
      # unconditional snapshot rewrite.
      # `rebaselined` (#1898) is true when the recheck found its served effect collections stale and answered with a
      # full baseline instead; see {#rebaseline_recheck}.
      # `stale_readers` (#1553) are the files the recheck re-analysed because a plugin read one of them made went
      # stale ({#plugin_read_affected}).
      Recheck = Data.define(:diagnostics, :changed, :added, :removed, :affected, :reused, :templates, :rebaselined,
                            :stale_readers) do
        def initialize(rebaselined: false, stale_readers: Set.new, **rest)
          super
        end

        # A recheck that changed, added, and removed nothing, and found no stale plugin read — the session state is
        # byte-equivalent to the snapshot that was restored, so persisting it again would only rewrite identical
        # bytes. A stale reader's refreshed rows differ (#1553): unsaved, every later run would re-analyse it.
        def no_change?
          changed.empty? && added.empty? && removed.empty? && stale_readers.empty?
        end
      end

      # @param paths — explicit analysis roots; nil (the default) uses the configuration's
      #   `paths:`.
      # @param environment — optional shared environment to thread into each internal
      #   Runner. Long-lived callers and specs can use this to avoid rebuilding the same RBS universe for
      #   every baseline / recheck / oracle run.
      # @param cache_store — ADR-85 WD1 — the persistent cache each internal Runner
      #   exposes to the RBS-env and plugin-producer tiers. A cross-process `--incremental` recheck otherwise
      #   rebuilt a fresh runner with no store, so every plugin `#prepare` producer (the ADR-9/#74/ADR-60 WD3
      #   record-and-validate caches) recomputed per invocation — 86% of a Rails warm incremental. Threading
      #   the store lets those producers serve from disk. `nil` (the default) preserves the pre-#85 behaviour
      #   the specs assert; the whole-run ADR-45 result cache stays disabled on these runs
      #   (`Runner#run_result_cacheable?` excludes `record_dependencies` / `analyze_only`).
      # @param plugin_requirer — optional gem-require hook threaded into each internal Runner
      #   (mirrors {Runner}'s parameter). nil (the default, and what the CLI passes) uses `Kernel.require`;
      #   embedders and specs inject a fake so a test plugin registers without touching the real load path.
      # @param workers — ADR-46 — the resolved fork-pool worker count threaded into every internal
      #   analyzer, so a `--incremental` recheck's closure re-analysis parallelises exactly like the standard
      #   `check` path (the recon's audit: `--workers` / `RIGOR_RACTOR_WORKERS` / `parallel.workers:` were
      #   silently ignored because `build_runner` passed no `workers:`). 0 (the default, and what the specs and
      #   `--verify-incremental` gate use) keeps the sequential recording path bit-for-bit unchanged. The fork
      #   pool records each worker's cross-file reads and marshals them back (PoolCoordinator), so the
      #   dependency graph a pooled recheck rebuilds equals the sequential one.
      def initialize(configuration:, paths: nil, environment: nil, cache_store: nil, plugin_requirer: nil, # rubocop:disable Metrics/ParameterLists,Metrics/AbcSize,Metrics/MethodLength
                     workers: 0, buffer: nil, explain: false, on_file_indexed: nil)
        @configuration = configuration
        # ADR-113 WD2 — `rigor lens`: {#force_targets=} names files a {#recheck} analyses whether or not they changed,
        # in this process, so `on_file_indexed` (see {Runner}) sees their seeded index. Neither moves a diagnostic:
        # a forced file re-analyses under the same seeds its cached rows were computed with.
        @force_targets = Set.new
        @on_file_indexed = on_file_indexed
        @paths = paths
        # Editor mode option B (#146) — the in-flight buffer, threaded into every internal Runner so the
        # pre-passes and the closure re-analysis read the editor's bytes at the logical path. A session
        # holding one MUST NOT persist its snapshot: its `@digests` and `@cache` describe bytes that exist
        # only in the editor. {#run_buffer_recheck} is the only entry that honours that.
        @buffer = buffer
        @environment = environment
        @cache_store = cache_store
        @plugin_requirer = plugin_requirer
        @workers = workers
        @explain = explain # #1533: threaded into every Runner; keys the snapshot, and no slot is written
        # ADR-85 WD2 — per-file discovery seed bundles keyed by logical path. A cold baseline builds them; a
        # warm recheck folds them (re-walking only changed files) and refreshes the set. Ride the snapshot.
        @seed_bundles = {}
        @cache = {}              # analyzed path => [Diagnostic]
        @sources = {}            # analyzed path => Set<source path it read from>
        @digests = {}            # analyzed path => ADR-87 packed stat-digest entry at last analysis
        # Issue #1583 — discovered-not-analysed path => the same packed entry, for a run over path arguments that
        # #684 widened to the configured `paths:`. Empty on every run over the configured paths.
        @discovery_digests = {}
        @analyzed = []           # the project files analyzed last round
        @dependents = {}         # inverted @sources (file-level)
        # ADR-46 slice 4 — symbol-granularity tracking.
        @symbol_sources = {}     # consumer => { source_path => Set<"ClassName#method"> }
        @ancestry_sources = {}   # consumer => Set<source_path> (class-ancestry deps)
        @symbol_fingerprints = {}  # path => { "ClassName#method" => sha256_hex }
        @symbol_dependents = {}    # [source, symbol] => Set<consumer>
        @ancestry_dependents = {}  # source => Set<consumer> (inverted ancestry_sources)
        # ADR-46 slice 3 — negative (missing) dependencies: a consumer that
        # looked up a name and resolved nothing must be re-checked when that
        # name later appears (e.g. a `call.unresolved-toplevel` whose target
        # is defined by a later edit).
        @missing = {}              # consumer => Set<"kind:name"> it looked up and missed
        @negative_dependents = {}  # "kind:name" => Set<consumer> (inverted @missing)
        @class_decls = {}          # path => Set<qualified class name declared in the file>
        # Issue #644 — the value-constant twin: path => { qualified constant name => publication descriptor }.
        # Diffed on a recheck to find every constant whose PUBLISHED answer could have moved, which satisfies
        # the `constant:` edges a reader records at every reference, resolved or not.
        @constant_decls = {}
        # ADR-89 WD2 — per-def observed-key return summaries: [path, symbol] => { keys:, returns:, effects: }.
        # Harvested from the ADR-84 return memo after each run; drives the behavioural-stability gate.
        @return_summaries = {}
        # ADR-67 WD6c lift — the `parameter_inference:` seed table the cached diagnostics were computed
        # under (`{}` when the gate is off — the gate state is constant across a snapshot's lifetime because
        # the configuration is part of the global fingerprint). A recheck recomputes the table fresh and
        # diffs it against this: the pre-pass is whole-project by design, so the fresh table is ground truth
        # and a missing invalidation edge is impossible by construction — the reason this is a table diff
        # and not the caller→callee edge recording #204 first sketched.
        @param_table = {}
        # Issue #1553 — analysed path => the plugin reads ({Plugin::IoBoundary.attributing}) its last analysis made:
        # the frozen `Cache::Descriptor::FileEntry` / `GlobEntry` rows, as each read observed its input. A recheck
        # re-analyses every file one of whose rows no longer validates ({#plugin_read_affected}).
        @plugin_reads = {}
        # Issue #2020 — the run-scoped plugin rows each analysed file registered, and the reads that make one stale.
        @plugin_disclosures = RunDisclosureLedger.new
        @stale_disclosures = Set.new
        reset_carried_state
        # ADR-88 WD1 — the plugin fact-surface digest computed for THIS invocation (nil until a
        # `#run_incremental` pass runs / a plugin-free project) and the reporting flags a caller (the CLI
        # banner + `--cache-stats`) reads after `#run_incremental`. `@last_runner` is the analysis runner the
        # post-hoc fingerprint reads from; `@plugin_fact_reusable` is the computed decision object.
        @plugin_fact_digest = nil
        @opaque_reasons = {}.freeze
        @fact_store_unreadable = false
        @fact_surface_invalidated = false
        @last_runner = nil
        @plugin_fact_reusable = nil
      end

      # ADR-113 WD2 — the paths (as {#project_files} spells them) every later {#recheck} analyses in this process.
      def force_targets=(paths)
        @force_targets = paths.to_set
      end

      # The project files a run of this session analyses, as the runner expands the configured paths.
      def project_files
        current_files
      end

      # Issue #1583 (and #1560) — whether a file the run discovers but does not analyse was edited, added or
      # removed since the snapshot. Such a file feeds the cross-file index the analysed files resolve against
      # (a constant, a method, an ancestor), but no recorded edge or digest of the analysed set sees it move.
      # A move re-baselines the session: discovery-only files are not tracked per symbol, so the closure
      # cannot be narrowed, and the full analysis is over the argument set alone. A session over the
      # configured `paths:` discovers nothing beyond what it analyses and pays nothing here.
      def discovery_moved?
        current = current_discovery_only_files
        return true unless current.size == @discovery_digests.size

        current.any? do |path|
          entry = @discovery_digests[path]
          entry.nil? || !Cache::FileDigest.stat_fresh?(path, entry)
        end
      rescue StandardError
        true
      end

      # A baseline's freshness entries: each analysed file's, and (issue #1583) each discovered-not-analysed file's.
      def record_baseline_digests
        @digests = @analyzed.to_h { |path| [path, pack_digest(path)] }
        @discovery_digests = current_discovery_only_files.to_h { |path| [path, pack_digest(path)] }
        forget_unbound_digests
      end

      def restore_digests(payload)
        @digests = payload.digests
        @discovery_digests = payload.discovery_digests # Issue #1583 — `{}` in a payload built without it.
      end

      # Issue #1583 — the discovered-not-analysed files of a run over this session's paths
      # ({Runner#discovery_only_file_set}). Asked of a runner WITHOUT the editor buffer: a buffered run does not
      # widen, so a buffered session (editor mode option B, #146) would read an empty set against the snapshot's
      # and re-baseline on every keystroke. Globbing without it keeps the comparison the one the snapshot's
      # writer made, so a sibling edit still declines option B and an unchanged project still serves it.
      def current_discovery_only_files
        return [] if @paths.nil?

        Runner.new(configuration: @configuration, cache_store: nil, environment: @environment)
              .discovery_only_file_set(@paths)
      end
      private :discovery_moved?, :record_baseline_digests, :restore_digests, :current_discovery_only_files

      # The per-file discovery bundles of the last run, keyed by path (ADR-85 WD2).
      attr_reader :seed_bundles

      # The project files `path`'s analysis read from at the last run that analysed it (ADR-46 slice 1).
      def dependency_sources(path)
        @sources.fetch(path, Set.new)
      end

      # The project files analyzed at the last baseline / recheck — the set a verify pass partitions and the
      # merge subtracts the affected closure from.
      def analyzed_files
        @analyzed
      end

      # ADR-103 WD12 / issue #382 — the session's effect graph: the fixpoint over the merged whole,
      # recomputed on every ask. This is the invariant that makes per-file collection reuse sound — the
      # closure is never partially reused, only its per-file *inputs* are, so a leaf edit whose new label
      # reaches a caller in an unchanged file still shows up in that caller's `reach`.
      def effect_table
        Effects::Propagator.propagate(
          effect_collection, discharge: Effects::Discharge.new(@configuration.effects_tolerated)
        )
      end

      # The merged direct summaries the table above closes over.
      def effect_collection
        Effects::FileCollection.merge_all(sorted_effect_collections)
      end

      # Where each unit was defined — the same shape (and the same purpose: the snapshot's `reach:` globs)
      # as `Runner#effect_sources`, answered from the session's own per-file collections.
      def effect_sources
        sorted_effect_collections.each_with_object({}) do |collection, out|
          path = collection.path
          next if path.nil?

          collection.summaries.each_key { |key| (out[key] ||= []) << path }
        end
      end

      # Full baseline analysis with recording. Returns the run's diagnostics; populates the in-process cache
      # + dependency state.
      def baseline
        @slot_carried_from = nil # ADR-45 WD2 — see {#load_snapshot}
        runner = build_runner(record_dependencies: true)
        diagnostics = run_runner(runner).diagnostics
        @last_runner = runner # ADR-88 WD1 — the post-hoc fact-surface fingerprint reads this prepared registry.
        # #392 — the template units are deliberately NOT in the analysed set. `Runner#target_files`
        # re-analyses every unit on every run, so a unit must never be reused from the per-file cache and
        # must never read as a file that VANISHED from the project on the next recheck (which is what
        # `previous - current` would say, `current_files` being a `.rb` expansion).
        @analyzed = runner.analyzed_files - runner.template_unit_paths
        # ADR-85 WD2 — the freshly built bundle set for the next run, each stamped with its file's source-RBS
        # digest (issue #1536).
        @seed_bundles = source_rbs_gate.stamp(runner.seed_bundles, whole_project: true)
        absorb_dependency_graph(runner)
        @return_summaries = runner.return_summaries # ADR-89 WD2 — the full-run behavioural surface.
        # ADR-67 WD6c lift — the seed table the runner's own pre-pass computed ({} when the gate is off).
        # Reading it back, rather than computing it here, keeps the baseline single-collect.
        @param_table = runner.param_inferred_types
        # ADR-103 WD13 / #382 — a baseline collects every file, so its collections are the whole world.
        @effect_collections = runner.effect_collections_by_path
        @effects_identity = current_effects_identity
        @effect_plugin_digest = effect_plugin_digest_of(runner)
        @cache = per_file(runner.per_file_diagnostics)
        @plugin_reads = plugin_reads_of(runner, @analyzed)
        @plugin_disclosures = RunDisclosureLedger.from(runner.analysis_disclosures.slice(*@analyzed))
        record_baseline_digests
        @run_level_rows = runner.run_level_rows
        diagnostics
      end

      # Re-check after on-disk edits, including files added or removed since the last run (the structural
      # tier). Re-analyzes only the affected closure and serves the rest from cache; refreshes the cache +
      # dependency state so a subsequent #recheck sees the new world.
      def recheck
        previous = @analyzed
        current = current_files
        added = current - previous
        removed = previous - current
        changed = changed_paths(current & previous)
        return rebaseline_recheck(changed, added, removed) if discovery_moved?

        # ADR-67 WD6c lift — recompute the whole-project inferred-param table BEFORE deciding the closure,
        # and diff it against the snapshot's copy: an entry that moved (because a caller's argument type
        # changed, a caller appeared, or one vanished) invalidates the CALLEE's file and its symbol
        # dependents, none of which the file-digest tier can see (the callee's text is unchanged).
        fresh_params = fresh_param_table(current, changed, added, removed)
        param_files, param_pairs = param_seed_invalidation(fresh_params)
        affected = affected_closure(changed, added, removed, param_files, param_pairs)
        forced, analyze_set = forced_analyze_set(affected, current)
        reused = (current & previous) - analyze_set.to_a
        # The freshly collected table is handed to the runner so the run seeds from the SAME table the diff
        # was decided on (and the collector runs once per recheck, not twice). The reused files' cached rows
        # go in too, so the runner lists them in the full run's file order (#1524).
        runner = build_runner(analyze_only: analyze_set, record_dependencies: true,
                              param_inferred_types: fresh_params, **forced_target_options(forced),
                              restored_run_level_rows: @run_level_rows, **served_state(reused))
        merged = run_runner(runner).diagnostics
        return rebaseline_recheck(changed, added, removed) if served_effects_stale?(runner, reused)

        absorb(runner, current, analyze_set, removed)
        @param_table = fresh_params
        recheck_result(merged, [changed, added, removed], affected: affected, reused: reused.to_set, runner: runner,
                                                          stale_readers: @stale_plugin_readers)
      end

      # Editor mode option B (#146) — a whole-project recheck with the editor's buffer substituted for one
      # file, for the CLI's `--incremental --tmp-file=X --instead-of=Y`. Returns the {Recheck} when the
      # snapshot could be reused, or nil when it could not — the caller then falls back to option A
      # (single-file scope) rather than paying a full baseline, because that baseline would repeat on every
      # keystroke: this session MUST NOT save, so nothing it computes can warm the next invocation.
      #
      # Not saving is the whole safety story. `@digests` and `@cache` here describe the buffer's bytes, which
      # exist only in the editor; persisting them would make the next `rigor check --incremental` believe the
      # on-disk file was already analysed in a state it was never in.
      def run_buffer_recheck(snapshot:, fingerprint:)
        Cache::FileDigest.with_run(strict: @configuration.cache_validation_strict?) do
          restored = fingerprint && snapshot.load(fingerprint: fingerprint)
          break nil unless restored

          restore(restored)
          result = recheck
          adopt_plugin_fact_fingerprint
          # The ADR-88 gate applies unchanged: if the plugin fact surface moved, the cache-served files may be
          # stale. A full baseline is the sound answer for `--incremental`, but in editor mode it is also the
          # latency this mode exists to avoid, so decline and let the caller drop to single-file scope.
          break nil unless @plugin_fact_reusable.reusable_against?(restored.plugin_fact_digest)
          break nil if source_rbs_unverified?(result)
          # #1898 — a recheck that re-baselined over stale plugin effect facts ran its baseline with the buffer set,
          # which analyses the buffer alone, so it is not a whole-project answer. Decline, as above.
          break nil if result.rebaselined

          result
        end
      end

      # The frozen set of files a #recheck must re-analyse: the symbol/ancestry-granularity closure of the
      # changed files (slice 4), the added files themselves, the consumers of any symbol / class that
      # *appeared* in a changed OR added file (slice 3 — a now-defined `call.unresolved-toplevel` target or
      # `def.override-*` ancestor), and the consumers of every removed file (which now miss what it
      # provided). An added file has no before-state, so all its symbols / classes appear.
      #
      # ADR-67 WD6c lift — `param_files` / `param_pairs` are the callee files (and their `[file, symbol]`
      # pairs) whose inferred-param seeds moved since the snapshot. Their text is unchanged, so they enter
      # the closure here: the files themselves re-analyse (their in-body diagnostics were computed under the
      # old seeds), and their pairs join the SYMBOL fan-out — a seed change shifts the callee's inferred
      # return exactly the way a body edit does, so it reuses the same audited dependents machinery. The
      # pairs join AFTER the ADR-89 WD2 behavioural-stability pruning: that gate re-evaluates returns under
      # the snapshot's OLD seeds, which is the wrong oracle for a pair whose seeds are the thing that moved.
      #
      # Issue #1536 (ADR-89 WD1 amendment) — every gate in {#gated_closure} reads the RUBY side of a file. What a
      # source-RBS synthesizer derives from its comments reaches the environment as a `virtual:` buffer, and a
      # reader of that RBS records no edge to the file it came from (an `attr_reader :name #: String` consumer
      # records none at all), so no dependent set can bound who read it. An edit that moved it re-analyses the
      # whole project — what a `sig/` edit already costs through the snapshot fingerprint.
      def affected_closure(changed, added, removed, param_files = Set.new, param_pairs = Set.new)
        @stale_plugin_readers = plugin_read_affected | disclosure_refreshers(removed)
        return whole_project_closure(changed, added) if source_rbs_gate.moved?(@seed_bundles, changed, added, removed)

        (gated_closure(changed, added, removed, param_files, param_pairs) | @stale_plugin_readers).freeze
      end

      # {#affected_closure} for an edit whose synthesized RBS is byte-identical in every file it touched.
      def gated_closure(changed, added, removed, param_files, param_pairs)
        scan = changed + added
        # Parse the changed / added set ONCE for the per-symbol fingerprints, the class declarations, AND the
        # ADR-89 WD1 declaration signatures. They were separate `discovered_def_index_for_paths` passes over
        # the same `scan` set — a duplicate re-parse of every changed file each recheck (recon §2 / the P6
        # recheck-floor audit).
        # `buffer:` is load-bearing for editor mode option B (#146), not an optimisation: this scan decides
        # the closure, so reading the buffer's logical path from DISK would compare the snapshot's symbol
        # fingerprints against bytes the user has already edited away — every dependent of the unsaved change
        # would then be served from cache, which is the stale answer whole-project editor scope exists to
        # avoid. `ScopeIndexer.scan_summary_for_paths` resolves each path through the binding.
        summary = scan.empty? ? nil : Inference::ScopeIndexer.scan_summary_for_paths(scan, buffer: @buffer)
        scan_index = summary && summary[:def_index]
        declaration_signatures = (summary && summary[:declaration_signatures]) || {}
        new_fps = symbol_fingerprints_from_index(scan_index)
        new_class_decls = class_declarations_from_index(scan_index)
        new_constant_decls = constant_declarations_from_index(scan_index)
        changed_pairs = Incremental.changed_symbol_pairs(changed, @symbol_fingerprints, new_fps)
        # ADR-89 WD1 — a changed file whose DECLARATION signature (per-def parameter shape / visibility /
        # ancestry / member layout / def line, bodies excluded) is byte-identical to the snapshot is
        # declaration-stable: every cross-file fact its ancestry / file-level dependents consume is
        # declaration-derived and therefore unchanged (a body edit is consumed only by SYMBOL dependents,
        # governed below by `changed_pairs`), so those dependents are skipped. Only the declaration-UNSTABLE
        # changed files contribute their ancestry / file-level dependents; the changed files themselves are
        # always re-analysed (`changed.to_set`) to learn their own diagnostics. This generalises the B1
        # comment-only gate (code-stable ⟹ declaration-stable) to same-line body edits.
        unstable = declaration_unstable(changed, declaration_signatures)
        # ADR-89 WD2 — a declaration-stable changed def whose behavioural surface (return type at every
        # previously-observed call key + content-mutation effects) is unchanged is behaviourally stable: its
        # symbol dependents' cached diagnostics stay valid, so drop them. `symbol_pairs` is `changed_pairs`
        # minus those stable pairs, and only it (not `changed_pairs`) drives the symbol-dependent fan-out.
        symbol_pairs = behaviourally_unstable_pairs(changed_pairs, unstable, scan_index) | param_pairs
        base = dependents_base(unstable, symbol_pairs)
        closure = base | changed.to_set | added.to_set |
                  negative_affected(scan, removed, new_fps, new_class_decls, new_constant_decls, summary)
        closure = param_seed_closure(closure, param_files)
        removed.each { |path| closure |= @dependents[path] || Set.new }
        closure.freeze
      end

      # Issue #1553 — every analysed file whose last analysis made a plugin read that no longer validates: a file
      # read through {Plugin::IoBoundary#read_file} or probed through `#file?` / `#directory?` was edited,
      # removed, or created after a read that found it absent, or a `#list_directory` / `#glob` listing moved.
      # The ADR-46 edges record type and declaration reads only, so none of these moves a reader into the
      # closure, and its cached rows were computed from the input as it was. The reader's own text is unchanged,
      # so it joins the closure alone: a plugin read made while analysing a dependent is credited to that
      # dependent. Each distinct row is validated once however many files made it (one `File.stat` for a
      # content row whose stat tuple did not move, one re-glob for a listing row).
      def plugin_read_affected
        verdicts = {}
        @plugin_reads.each_with_object(Set.new) do |(path, rows), stale|
          next unless rows.any? { |row| !verdicts.fetch(row) { verdicts[row] = plugin_read_fresh?(row) } }

          stale << path
        end
      end

      def plugin_read_fresh?(row)
        if row.is_a?(Cache::Descriptor::GlobEntry)
          Cache::Descriptor::GlobEntry.fresh?(row)
        else
          Cache::Descriptor.new(files: [row]).fresh?
        end
      end

      # Issue #1553 — `runner`'s per-file plugin reads for `paths`, each file's rows de-duplicated and frozen.
      def plugin_reads_of(runner, paths)
        runner.analysis_reads.slice(*paths).transform_values { |rows| rows.uniq.freeze }
      end

      # Issue #1906 — a file that rewrites a constant's singleton names without declaring it
      # (`D.singleton_class.alias_method :own, :keep`, or, since #1941, `def D.own`) contributes opaque singleton
      # envelopes to the constant's bucket, but a reader's class edge names only the files that declared the constant
      # when the reader last ran, and the class-declaration diff does not move while the constant stays in the file
      # (`:own` becoming `:keep`, or the call becoming a `class D` reopening). So a declaration-unstable edit to such a
      # file fires `class:<last segment>` for each constant that, before the edit, both sat in the file's
      # singleton-source set and held a singleton envelope entry or an unpositioned singleton side the file recorded (a
      # computed name there leaves the side unpositioned, and becoming literal reads it again). A file that only
      # includes into a constant (`ActiveRecord::Base.include(X)`) records neither and fires nothing. A constant the
      # edit makes the file rewrite needs no key: the class-declaration diff fires if it is new to the file, and the
      # reader's class edge names the file if the file declared it.
      def singleton_rewrite_affected(unstable)
        names = unstable.flat_map { |path| singleton_rewritten_constants(@seed_bundles[path]) }.uniq
        return Set.new if names.empty?

        Incremental.negative_closure(names.map { |name| "class:#{name.split('::').last}" }, @negative_dependents)
      end

      def singleton_rewritten_constants(bundle)
        return [] if bundle.nil?

        envelopes = bundle[:parameter_envelopes] || {}
        unpositioned = bundle[:unpositioned_mixins] || {}
        (bundle[:singleton_class_source_names] || []).select do |name|
          (envelopes[name] || {}).each_key.any? { |key| key.is_a?(Array) && key.first == :singleton } ||
            unpositioned.dig(name, :extend)
        end
      end

      # Issue #1367 — every file whose last result holds a `global.*` diagnostic re-checks on any recheck. What
      # exempts such a write is a fact of the whole program — an alias, or a `write` / `to_str` / `to_int` / hatch
      # defined in any spelling on any receiver, a rewritten ancestor, a mixin — which no name-keyed edge can
      # follow, so a stale report would outlive the edit that exempts it. Such files are rare, so this costs little.
      # A file the census silenced is re-checked through the `global_census:` keys its rule recorded
      # ({#global_census_affected}, issue #2158).
      def global_write_reporters
        @cache.each_with_object(Set.new) do |(path, diagnostics), reporters|
          reporters << path if diagnostics.any? { |diagnostic| diagnostic.rule.to_s.start_with?("global.") }
        end
      end

      # ADR-67 WD6c lift — the seed-invalidated callees' own contribution to the closure: the files
      # themselves, plus — on a pre-slice-4 snapshot with no symbol edges, where the pairs' symbol fan-out
      # found nothing — their file-level dependents (wider, always sound).
      def param_seed_closure(closure, param_files)
        closure |= param_files
        param_files.each { |path| closure |= @dependents[path] || Set.new } if @symbol_sources.empty?
        closure
      end

      # The dependents contributed by the declaration-unstable changed files and the behaviourally-unstable
      # symbol pairs: the ADR-46 slice-4 symbol-granular fan-out when either is present (ancestry deps of the
      # unstable files + symbol deps of the changed pairs), else the coarse file-level fan-out; plus the readers of
      # the constants an unstable file rewrote from outside their bodies ({#singleton_rewrite_affected}).
      def dependents_base(unstable, symbol_pairs)
        base = if symbol_pairs.any? || unstable.any? { |f| @ancestry_dependents[f] }
                 Incremental.affected_with_symbols(unstable, symbol_pairs, @symbol_dependents, @ancestry_dependents)
               else
                 Incremental.affected(unstable, @dependents)
               end
        base | singleton_rewrite_affected(unstable)
      end

      # ADR-67 WD6c lift — the fresh whole-project inferred-param table for this recheck ({} when the gate
      # is off). When NO file moved, the collector's inputs are unchanged — the project files are identical,
      # and the env-side inputs (configuration, `sig/`, the gem set, the engine version) are constant under
      # a matched snapshot fingerprint — so the stored table is provably identical and the whole-project
      # re-collect is skipped (the ADR-87 null-recheck fast path stays collect-free).
      def fresh_param_table(current, changed, added, removed)
        return {} unless @configuration.parameter_inference
        return @param_table if changed.empty? && added.empty? && removed.empty?

        build_runner.collect_param_inference_table(current)
      end

      # ADR-67 WD6c lift — the `[files, pairs]` the fresh table invalidates. For every `[class, method,
      # kind]` entry that differs from the snapshot's copy (added, removed, or value-changed — `Type#==`
      # structural equality, the same comparison the collector's own fixpoint termination uses, already
      # exercised across Marshal round-trips by its fork workers), every snapshot file defining that symbol
      # re-analyses and its `[file, symbol]` pair joins the symbol fan-out. An entry attributable to NO
      # snapshot file is a def that first appeared in this edit: its file is in the changed/added set (so it
      # re-analyses anyway) and its prior callers are the negative-dependency closure's job — nothing is
      # lost by skipping it here. The restored types are compared and then DISCARDED (the run seeds from the
      # fresh table), so a cache-carried stale memo ivar can never poison a live lookup.
      def param_seed_invalidation(fresh_params)
        return [Set.new, Set.new] if fresh_params.equal?(@param_table) || @param_table == fresh_params

        files = Set.new
        pairs = Set.new
        (@param_table.keys | fresh_params.keys).each do |key|
          next if @param_table[key] == fresh_params[key]

          class_name, method_name, kind = key
          symbol = "#{class_name}#{kind == :singleton ? '.' : '#'}#{method_name}"
          @symbol_fingerprints.each do |path, symbols|
            next unless symbols.key?(symbol)

            files << path
            pairs << [path, symbol]
          end
        end
        [files, pairs]
      end

      # ADR-89 WD2 — `changed_pairs` minus the behaviourally-STABLE pairs whose symbol dependents may be
      # skipped. A pair `[path, "Class#method"]` is a candidate when its file is declaration-stable (WD1), it
      # carries a persisted return summary, and the (edited) def is GATE-ELIGIBLE — its only cross-file body
      # surfaces are its return type and its content-mutation effects (no instance/class variable write, no
      # `yield`, no implicit-self call whose transitive effect a caller could observe). For a candidate the
      # session compares its content-mutation effects (pure AST) then re-evaluates its return at every
      # persisted key (a runner probe); a pair passes only when BOTH are unchanged. Any missing summary,
      # ineligible def, changed effect, changed return, or uncomputable key keeps the pair — the conservative
      # direction the `--verify-incremental` and byte-identical recheck specs backstop.
      def behaviourally_unstable_pairs(changed_pairs, unstable, scan_index)
        return changed_pairs if @return_summaries.empty? || scan_index.nil?

        candidates = changed_pairs.select do |pair|
          !unstable.include?(pair.first) && @return_summaries.key?(pair) &&
            gate_eligible_def?(scan_def_node(pair.last, scan_index))
        end
        return changed_pairs if candidates.empty?

        effect_stable = candidates.select { |pair| effects_unchanged?(pair, scan_index) }
        return changed_pairs if effect_stable.empty?

        stable = return_stable_pairs(effect_stable, scan_index)
        stable.empty? ? changed_pairs : (changed_pairs - stable)
      end

      # ADR-89 WD1 — the changed files whose ancestry / file-level dependents must STILL be re-checked: those
      # not provably declaration-stable. A changed file is declaration-STABLE (its ancestry / file-level
      # dependents skippable) when its current {ScopeIndexer.declaration_signature} matches the one stored in
      # the snapshot's seed bundle — i.e. its edit changed no method signature, visibility, ancestry, member
      # layout, def line, or method existence, so every cross-file DECLARATION fact its dependents consume is
      # unchanged. The signature reads code, not comments; the other half of stability — that no source-RBS
      # synthesizer's output for the file moved — is settled before this runs ({SourceRbsGate#moved?}), so every
      # file reaching here has a byte-identical synthesized contribution. Sorbet sigs / dry-types includes are
      # CODE, captured by ADR-88's plugin-fact fingerprint (WD3).
      def declaration_unstable(changed, declaration_signatures)
        changed.reject { |path| declaration_stable?(path, declaration_signatures[path]) }
      end

      def declaration_stable?(path, current_declaration_signature)
        return false if current_declaration_signature.nil?

        bundle = @seed_bundles[path]
        return false if bundle.nil?

        bundle[:declaration_signature] == current_declaration_signature
      end

      # Every file this recheck can analyse: the removed ones drop out at `affected & current`.
      def whole_project_closure(changed, added)
        (@analyzed.to_set | changed | added).freeze
      end
      private :gated_closure, :whole_project_closure, :singleton_rewrite_affected, :singleton_rewritten_constants

      # The current project file set (cheap directory expansion, no analysis), used to detect files added /
      # removed since the last run. Also where an editor buffer's binding is re-spelled onto the set, since
      # this is where the run first learns how it spells its own members.
      def current_files
        runner = build_runner
        files = @paths ? runner.analysis_file_set(@paths) : runner.analysis_file_set
        rebind_buffer(files)
        files
      end

      # Verification engine (the `--verify-incremental` gate): with NO source edit, re-analyze `subset` fresh
      # and serve every other analyzed file from the baseline cache. Because nothing on disk changed, the
      # merged result MUST equal a full analysis — so this exercises the subset-analysis and cache-merge
      # paths against a known-good oracle (a full `--no-cache` run) for an arbitrary partition, without
      # mutating session state. Returns the merged diagnostics.
      def reanalyze_subset(subset)
        affected = subset.to_set
        reused = @analyzed - affected.to_a
        # ADR-67 WD6c lift — seed the subset run from the baseline's own table so the verification engine
        # exercises the exact seeds the served cache entries were computed under (and skips a re-collect).
        runner = build_runner(analyze_only: affected, param_inferred_types: @param_table,
                              restored_run_level_rows: @run_level_rows, **served_state(reused))
        run_runner(runner).diagnostics
      end

      # Cross-process incremental run (the `--incremental` flag's engine). With a disk `snapshot` whose
      # `fingerprint` matches, restore the prior per-file state and `#recheck` (re-analyze only the changed
      # closure, serve the rest from the restored cache); otherwise run a full `#baseline`. Either way,
      # persist the updated snapshot for the next process. Returns `[diagnostics, warm]` — `warm` is true
      # when a snapshot was restored. A nil `fingerprint` (uncomputable inputs) disables persistence: a
      # plain full run.
      # `persist: false` runs the same restore / recheck / baseline decision without writing the snapshot
      # back. The language server (#246) needs exactly that: it keeps its session in memory for the life of
      # the process, and writing shared state would race the way its read-only cache store already declines
      # to. Every soundness gate below — the fingerprint, the ADR-88 fact surface — is unchanged, so the
      # decision to reuse is made identically whether or not the result is saved.
      def run_incremental(snapshot:, fingerprint:, persist: true)
        @last_recheck = nil # #1526 — set only by a warm recheck, see {#last_recheck}
        # ADR-87 WD1 — install the per-run digest table + recording instant + strict flag for the whole
        # invocation so change-detection's stat-then-digest freshness (`#pack_digest` / `#stat_fresh?`) honours
        # `cache.validation: digest` (and `RIGOR_STRICT_VALIDATION`, which the env-only path already sees) and
        # shares one digest memo across change detection and the baseline/absorb re-pack. The inner
        # `Runner#run` nests its own `with_run` for the analysis descriptors; nesting is safe (each restores).
        Cache::FileDigest.with_run(strict: @configuration.cache_validation_strict?) do
          restored = load_snapshot(snapshot, fingerprint)
          # ADR-88 WD1 — the plugin fact-surface fingerprint gates snapshot reuse the same way the global
          # fingerprint gates the load: a plugin sig/catalog edit outside `signature_paths:` (a Sorbet `.rbi`)
          # changes the types unchanged call sites resolve, without moving any analyzed file, so the global
          # fingerprint stays fresh and the recheck would serve stale diagnostics. The fingerprint is computed
          # POST-HOC from the analysis runner (which already ran `#prepare` and validated its producers) so the
          # warm path pays no second `#prepare`; the decision is applied after the recheck. Opaque plugins
          # (types with no fingerprint surface) make the snapshot un-reusable.
          if restored
            restore(restored)
            # ADR-103 WD13 / #382 — the effects sidecar joins the same reuse decision, for a structurally
            # identical reason: a snapshot whose summaries were collected under a different vocabulary /
            # catalogue / `effects:` block restores as empty, and a recheck only re-collects the changed
            # closure, so the merged table would be missing every unchanged file. A full baseline is the
            # honest answer — it is what "recompute effects" means when collecting requires analysing, and
            # it is paid on the first collecting run and on an identity change, never with collection off.
            # Asked BEFORE the recheck, which re-stamps the session with the current identity.
            effects_reusable = effects_reuse_permitted?(restored)
            result = recheck
            adopt_plugin_fact_fingerprint
            fact_reusable = @plugin_fact_reusable.reusable_against?(restored.plugin_fact_digest)
            if fact_reusable && effects_reusable && !result.rebaselined && !source_rbs_unverified?(result)
              diagnostics = keep_recheck(result)
              warm = true
              # ADR-87 WD3 — a warm recheck that changed nothing leaves the session state byte-equivalent to the
              # snapshot it restored, so skip the unconditional rewrite (209ms + 2 MB on gitlab per null recheck).
              # A cold baseline always persists — there was no valid snapshot to reuse.
              skip_save = result.no_change?
            else
              # The fact surface moved (a plugin sig/catalog edit), a plugin is opaque, the effects identity
              # moved, or a synthesizer the source-RBS gate could not see was loaded (#1536): the cached-served
              # files the recheck merged may be stale (or, for effects, a partial collection cannot be closed),
              # so re-analyze the whole tree. The current fact-surface
              # digest (from the recheck runner) is unchanged by the re-analysis, so it is kept for the save.
              # Only a genuine fact-surface reason sets the reporting flag the CLI banner reads.
              @fact_surface_invalidated = true unless fact_reusable
              # #1898 — a recheck that already re-baselined over stale plugin effect facts is that re-analysis.
              diagnostics = result.rebaselined ? result.diagnostics : baseline
              warm = false
              skip_save = false
            end
          else
            diagnostics = baseline
            adopt_plugin_fact_fingerprint
            warm = false
            skip_save = false
          end
          persist_run(snapshot, fingerprint, diagnostics, skip_save: skip_save) if persist && fingerprint
          [diagnostics, warm]
        end
      end

      # ADR-88 WD1 — reporting hooks the CLI reads after {#run_incremental}. `fact_surface_invalidated?` is true
      # when a valid snapshot was dropped for a fact-surface reason (a plugin sig/catalog edit, or an opaque
      # plugin) rather than a cold miss. `opaque_reasons` maps each plugin that forces a full run every invocation
      # to its {PluginFactFingerprint::OpaqueReason}.
      attr_reader :opaque_reasons

      # #1526 — the {Recheck} of the last {#run_incremental}, or nil unless that run answered warm. A baseline
      # (cold, or a re-baseline after a fact-surface, effects or source-RBS reason) has no recheck to report.
      # The diagnostics are not kept: a long-lived session (the LSP) would otherwise retain every merged list.
      attr_reader :last_recheck

      # Records the warm recheck's sets for {#last_recheck} and hands back its diagnostics.
      def keep_recheck(result)
        @last_recheck = result.with(diagnostics: [])
        result.diagnostics
      end
      private :keep_recheck

      # The opaque plugin ids, sorted (the keys of {#opaque_reasons}).
      def opaque_plugin_ids
        @opaque_reasons.keys
      end

      # True when the fact store could not be read, so no single plugin is named (see {PluginFactFingerprint::Result}).
      def fact_store_unreadable?
        @fact_store_unreadable
      end

      # True when the fact surface forces a full run: some plugin is opaque, or the fact store is unreadable.
      def opaque_fact_surface?
        !@opaque_reasons.empty? || @fact_store_unreadable
      end

      def fact_surface_invalidated?
        @fact_surface_invalidated
      end

      private

      # Path-sorted, so the fold is reproducible whatever order the files were absorbed in (the same reason
      # `Runner#effect_collections` sorts).
      def sorted_effect_collections
        @effect_collections.sort_by { |path, _| path.to_s }.map(&:last)
      end

      # ADR-88 WD1 — capture this invocation's fact-surface fingerprint (from the last analysis runner) onto the
      # reporting ivars + the `@plugin_fact_reusable` decision object.
      #
      # Issue #1536 — the same prepared registry settles whether the synthesizers the session digested with
      # are the ones the run's environment was built from ({SourceRbsGate#verify}). A plugin that builds its
      # synthesizer in `#prepare` leaves the gate untrusted, and every stored digest is stamped unknown before
      # the snapshot is saved.
      def adopt_plugin_fact_fingerprint
        registry = prepared_plugin_registry
        fact = compute_plugin_fact_fingerprint(registry)
        @plugin_fact_digest = fact.digest
        @opaque_reasons = fact.opaque_reasons
        @fact_store_unreadable = fact.fact_store_unreadable
        @plugin_fact_reusable = fact
        @seed_bundles = source_rbs_gate.verify(registry, @seed_bundles)
      end

      # Issue #1536 — a recheck of an edit whose closure left some file out may have under-read a synthesizer
      # the gate could not see. {#run_incremental} re-analyses the project and {#run_buffer_recheck} declines,
      # the way each treats a moved plugin fact surface. A run that changed nothing is exempt: under an
      # untrusted gate every earlier edit already re-analysed the whole project, so the snapshot it serves is
      # whole, and a null run stays one. A recheck that found a stale plugin read (#1553) is a change.
      def source_rbs_unverified?(result)
        source_rbs_gate.untrusted? && !result.no_change? && !result.reused.empty?
      end

      # Issue #1536 — a file the gate could not stamp because it was saved after the closure was decided (its
      # readers' cached answers predate that save) must read as changed on the next run, where its unknown
      # stamp sends the edit to the whole project. Recording its post-save content digest would hide it.
      def forget_unbound_digests
        source_rbs_gate.unbound.each { |path| @digests.delete(path) }
      end

      # Issue #1536 — decides whether an edit moved synthesized RBS, and stamps each seed bundle's digest. One
      # per session: its untrusted state must outlive every run the session makes.
      def source_rbs_gate
        @source_rbs_gate ||= SourceRbsGate.new(configuration: @configuration, cache_store: @cache_store,
                                               plugin_requirer: @plugin_requirer)
      end

      # ADR-88 WD1 — the plugin fact-surface fingerprint for this invocation. For a SEQUENTIAL run it is read
      # post-hoc from the analysis runner's already-prepared registry (no second `#prepare`, producers already
      # validated during analysis). A POOLED run's main process does not run `#prepare` on it (its workers do),
      # so its registry carries no published facts — there it falls back to the always-sequential probe. Both
      # paths compute the identical digest for a given fact surface, so the reuse decision is worker-count-independent
      # (the parity spec asserts this).
      def compute_plugin_fact_fingerprint(registry = prepared_plugin_registry)
        PluginFactFingerprint.from_registry(registry)
      end

      # The registry the run's environment was built from, after `#prepare`: the analysis runner's own on a
      # sequential run, the always-sequential probe's on a pooled one (nil when the probe fails).
      def prepared_plugin_registry
        registry = @last_runner&.plugin_registry
        return registry if @workers.zero? && registry && !registry.empty?

        PluginFactFingerprint.prepared_registry(
          configuration: @configuration, cache_store: @cache_store, plugin_requirer: @plugin_requirer
        )
      end

      # Loads the snapshot, noting (ADR-45 WD2) which write of the file it read: the identity is kept only when
      # the file was the same before and after the read, since a rewrite in between leaves no telling which one
      # the payload came from.
      def load_snapshot(snapshot, fingerprint)
        @slot_guard = start_slot_guard(fingerprint)
        before = snapshot_identity(snapshot)
        restored = fingerprint && snapshot.load(fingerprint: fingerprint)
        @restored_snapshot_identity = restored && before == snapshot_identity(snapshot) ? before : nil
        # The path set the previous run-result slot is keyed by, for a recheck to carry its chain from; a
        # {#baseline} clears it, since a full run starts a chain of its own.
        @slot_carried_from = restored&.analyzed
        restored
      end

      # ADR-87 WD3 — a warm recheck that changed nothing skips the snapshot rewrite: the file it restored is still
      # the one on disk, which is what the run-result slot records as its snapshot.
      def persist_run(snapshot, fingerprint, diagnostics, skip_save:)
        written = if skip_save
                    @restored_snapshot_identity
                  elsif snapshot.save(fingerprint: fingerprint, payload: to_payload)
                    snapshot_identity(snapshot)
                  end
        write_run_slot(diagnostics, written_identity: written)
      end

      # ADR-45 WD2 (#1507) — records this run's answer as the run-result slot a later `rigor check --incremental`
      # serves without loading the engine ({IncrementalRunSlot}). The slot's dependency descriptor must validate
      # what the answer was computed from, and after a narrowed recheck most of the answer was computed by earlier
      # runs, so it is assembled from three sources:
      #
      # - the analysed files, at the digest this session holds for each: the bytes its cached or fresh rows were
      #   computed from, never a re-digest taken after the fact;
      # - what this run read and re-derives every run ({Runner#incremental_slot_rows}' `observed` and `derived`
      #   rows);
      # - the CHAIN: the rows the last full run recorded for inputs a recheck does not re-derive
      #   ({Runner#baseline_dependency_rows}), and the plugin reads credited to each file's analysis. A full run
      #   starts a chain; a recheck takes the previous slot's, replaces the reads of every file it re-analysed with
      #   this run's, and drops the removed files'.
      #
      # A recheck writes only when the previous slot exists and was written against the very snapshot file it
      # restored: otherwise some run in between — a pool run, `--no-cache`, a write that failed — analysed files
      # without recording their reads, and the chain cannot vouch for them. It then writes nothing, and the next
      # full run starts a fresh chain. Declining to write is always safe; it only leaves the next null run on the
      # full path.
      #
      # Every row not recorded as a plugin read it must still describe the tree the run read
      # ({IncrementalRunSlot::WriteGuard}): the analysed files' (whose session digest a full run takes after its
      # analysis), the `derived` rows, and the chain's baseline, taken now or carried ({#guarded_rows}).
      #
      # @param written_identity — the snapshot file as this run leaves it, recorded for the next writer's check.
      def write_run_slot(diagnostics, written_identity:)
        return unless run_slot_writable?

        roots = @paths || @configuration.paths
        rows = @last_runner.incremental_slot_rows(roots: roots)
        chain = rows && (@slot_carried_from ? carry_chain(rows, roots) : start_chain(rows))
        analysed = chain && analysed_file_rows
        return if analysed.nil?

        baseline, pinned, reads = chain
        return unless @slot_guard&.admits?(guarded_rows(analysed, rows.derived, baseline), pinned: pinned)

        # A save the run read after the mark's tick must not hide behind an unmoved stat tuple.
        reads = reads.transform_values { |descriptor| @slot_guard.mark_racy(descriptor) }

        entry = IncrementalRunSlot::Entry.new(
          diagnostics: diagnostics, roots: IncrementalRunSlot.as_written(roots),
          baseline: baseline, pinned: pinned, reads: reads, snapshot: written_identity
        )
        dependencies = @slot_guard.mark_racy(run_slot_dependencies(analysed, rows, [baseline, pinned], reads.values))
        wrote = IncrementalRunSlot.write(
          store: @cache_store, configuration: @configuration, entry: entry, dependencies: dependencies,
          target: IncrementalRunSlot::Target.new(files: @analyzed, roots: roots)
        )
        discard_previous_slot(roots) if wrote
      rescue StandardError
        nil
      end

      # The previous slot is keyed by the previous path set; once this run's stands, nothing asks for it again.
      def discard_previous_slot(roots)
        return if @slot_carried_from.nil? || @slot_carried_from.sort == @analyzed.sort

        IncrementalRunSlot.discard(
          store: @cache_store, configuration: @configuration,
          target: IncrementalRunSlot::Target.new(files: @slot_carried_from, roots: roots)
        )
      end

      # ADR-45 WD2 — the mark {IncrementalRunSlot::WriteGuard#admits?} checks the slot's rows against, taken before
      # the run reads anything. nil (no slot this run) for a store no slot is written to, or no fingerprint.
      def start_slot_guard(fingerprint)
        return nil if fingerprint.nil? || @cache_store.nil? || @cache_store.read_only? || !@buffer.nil?
        # Known before the run: none of these can be written afterwards, so the stamp and the recomputed
        # fingerprint would be spent for nothing.
        # `WriteGuard.start` would also refuse (it recomputes the fingerprint without `explain:`); say so here.
        return nil unless @workers.zero? && !@configuration.effects_enabled? && !@explain

        IncrementalRunSlot::WriteGuard.start(
          configuration: @configuration, roots: @paths || @configuration.paths, cache_root: @cache_store.root,
          fingerprint: fingerprint
        )
      end

      # The runs whose answer the slot may hold: a writable store, no editor buffer (whose bytes exist only in
      # the editor), a sequential run (a pool worker's plugin reads never reach this process), effect collection
      # off ({IncrementalRunSlot.serve} declines it), and no opaque plugin — the next full-path run would then be
      # cold, not the warm run the probe stands in for.
      def run_slot_writable?
        !@cache_store.nil? && !@cache_store.read_only? && @buffer.nil? && @workers.zero? &&
          !@configuration.effects_enabled? && !@explain && !opaque_fact_surface? && !@last_runner.nil?
      end

      def start_chain(rows)
        baseline = @last_runner.baseline_dependency_rows(files: @analyzed)
        baseline && [baseline.owned, baseline.pinned, rows.by_file.slice(*@analyzed)]
      end

      def carry_chain(rows, roots)
        return nil if @restored_snapshot_identity.nil?

        previous = IncrementalRunSlot.previous_entry(
          store: @cache_store, configuration: @configuration,
          target: IncrementalRunSlot::Target.new(files: @slot_carried_from, roots: roots)
        )
        return nil if previous.nil? || previous.snapshot != @restored_snapshot_identity

        served = previous.reads.except(*@last_runner.analyzed_files)
        [previous.baseline, previous.pinned, served.merge(rows.by_file).slice(*@analyzed)]
      end

      # One `:stat` row per analysed file, from the entry this session recorded for it (`#pack_digest`), re-packed
      # against the file's current stat when the bytes still hash to the recorded digest but the tuple moved (a
      # `touch`, a checkout): the snapshot keeps the old tuple, and a row carrying it would cost every later probe
      # a re-hash of the file. nil when any file has no usable entry (it could not be read): no row could say what
      # its answer was computed from.
      def analysed_file_rows
        @analyzed.map do |path|
          packed = Cache::FileDigest.refresh_stat(path, @digests[path])
          return nil if packed.nil?

          Cache::Descriptor::FileEntry.new(path: path, comparator: :stat, value: packed)
        end
      end

      # @param chained — the chain's baseline descriptors, owned and pinned
      def run_slot_dependencies(analysed, rows, chained, reads)
        carried = chained + reads
        Cache::Descriptor.new(
          files: analysed + rows.derived.files + rows.observed.files + carried.flat_map(&:files),
          globs: (rows.derived.globs + rows.observed.globs + carried.flat_map(&:globs)).uniq
        )
      end

      # What the write guard asks about besides the pinned baseline: every row the key does not pin that was not
      # recorded as a plugin read it. A recheck's carried baseline is among them. The run that took it vouched for
      # the tree it saw, but this run reads those inputs again (a recheck with a non-empty closure rebuilds its
      # environment from the signature tree), and a save it read that is reverted before the run ends leaves every
      # carried row fresh while the answer came from the saved bytes.
      def guarded_rows(analysed, derived, baseline)
        Cache::Descriptor.new(files: analysed + derived.files + baseline.files, globs: derived.globs + baseline.globs)
      end

      # The snapshot file's `(size, mtime_ns, ctime_ns, inode)`: which write of it a run restored, or left behind.
      # A rewrite renames a new file into place, so any write moves it. nil when there is no file to stat.
      def snapshot_identity(snapshot)
        path = snapshot.respond_to?(:path) ? snapshot.path : nil
        return nil if path.nil?

        stat = File.stat(path)
        [stat.size, Cache::FileDigest.ns_of(stat.mtime), Cache::FileDigest.ns_of(stat.ctime), stat.ino]
      rescue SystemCallError
        nil
      end

      # Adopt a persisted snapshot's per-file state as this session's baseline (the warm-start path).
      def restore(payload)
        @analyzed = payload.analyzed
        @cache = payload.cache
        @sources = payload.sources
        restore_digests(payload)
        # ADR-85 WD2 — restore the per-file discovery bundles if present (absent in a pre-#85 snapshot → empty,
        # so the recheck's discovery re-walks every file: a cold-quality index, always sound). The SCHEMA bump
        # makes a genuinely stale-shaped bundle unreadable rather than mis-folded.
        @seed_bundles = payload.seed_bundles || {}
        @dependents = Incremental.invert(@sources)
        # ADR-46 slice 4 — restore symbol-granularity state if present in the payload (absent in snapshots
        # written before slice 4 → fall back to file-level dependents, which is always sound).
        @symbol_sources    = payload.symbol_sources    || {}
        @ancestry_sources  = payload.ancestry_sources  || {}
        @symbol_fingerprints = payload.symbol_fingerprints || {}
        restore_structural_declarations(payload)
        @return_summaries  = payload.return_summaries || {}
        @param_table       = payload.param_table || {} # ADR-67 WD6c lift — the seeds the cache was built under.
        restore_plugin_records(payload)
        # Issues #796 / #794 — absent (nil) in a snapshot written before schema 22 is impossible (the SCHEMA
        # gate rejects one), so nil here means the writing run genuinely had nothing to say.
        @run_level_rows    = payload.run_level_rows
        # ADR-103 WD13 / #382 — the effects sidecar rides its own identity, so a snapshot whose summaries
        # were collected under a different vocabulary / catalogue / `effects:` block restores as EMPTY
        # rather than as stale rows. {#run_incremental} turns that emptiness into a full baseline, because
        # a partial re-collection cannot be closed into a whole-project fixpoint.
        @effects_identity  = payload.effects_identity
        @effect_collections = effect_collections_reusable?(payload) ? payload.effect_collections.dup : {}
        @effect_plugin_digest = payload.effect_plugin_digest
        @symbol_dependents = Incremental.invert_symbols(@symbol_sources)
        @ancestry_dependents = Incremental.invert(@ancestry_sources)
        @negative_dependents = Incremental.invert(@missing)
      end

      # Issue #1553 — the plugin reads each file's last analysis made, and (#2020) the run-scoped plugin rows it
      # registered; `{}` in a payload built without them. Extracted to keep {#restore} under its ABC budget.
      def restore_plugin_records(payload)
        @plugin_reads = payload.plugin_reads
        @plugin_disclosures = RunDisclosureLedger.load(payload.plugin_disclosures)
      end

      # ADR-46 slice 3 / issue #644 — the structural tier's negative-edge state: the per-consumer missed
      # lookups plus the two per-file DECLARATION sets (`class_decls`, `constant_decls`) whose diff says what
      # APPEARED in an edit. Absent in an older snapshot → empty, which only loses the appeared-symbol
      # refinement; such a snapshot is never loaded by a newer engine (the version + SCHEMA are part of the
      # fingerprint) and `--verify-incremental` backstops any residual under-capture. Extracted to keep
      # {#restore} under its ABC budget.
      def restore_structural_declarations(payload)
        @missing        = payload.missing || {}
        @class_decls    = payload.class_decls || {}
        @constant_decls = payload.constant_decls || {}
      end

      def to_payload
        Cache::IncrementalSnapshot::Payload.new(
          cache: @cache, sources: @sources, digests: @digests, analyzed: @analyzed,
          symbol_sources: @symbol_sources, ancestry_sources: @ancestry_sources,
          symbol_fingerprints: @symbol_fingerprints, missing: @missing,
          class_decls: @class_decls, constant_decls: @constant_decls, seed_bundles: @seed_bundles,
          plugin_fact_digest: @plugin_fact_digest,
          return_summaries: marshal_safe_return_summaries,
          param_table: marshal_safe_param_table,
          effect_collections: marshal_safe_effect_collections,
          effects_identity: @effects_identity,
          run_level_rows: @run_level_rows,
          effect_plugin_digest: @effect_plugin_digest,
          plugin_reads: @plugin_reads,
          plugin_disclosures: @plugin_disclosures.to_h,
          discovery_digests: @discovery_digests
        )
      end

      # ADR-103 WD13 / issue #382 — the per-file effect collections the session serves unchanged files
      # from, and the effects identity they were collected under. Empty / nil when collection is off, which
      # is every run that does not carry an `effects:` block. The PROPAGATED table is never kept here:
      # {#effect_table} re-runs the fixpoint over the merged whole on every ask, because a leaf's summary
      # reaches every caller and there is no per-file invalidation for a whole-graph closure.
      def reset_effect_state
        @effect_collections = {}
        @effects_identity = nil
        @effect_plugin_digest = nil
      end

      # The state this session carries ACROSS processes in the snapshot rather than deriving each run: the
      # effects sidecar above, and (issues #796 / #794) the run-level rows the last FULL run answered — the
      # `definition-build-failed` set and the HKT-scan outcome, nil until a full run has produced them, and
      # handed to every narrowed run this session builds, none of which can derive them from its own files.
      def reset_carried_state
        reset_effect_state
        @run_level_rows = nil
      end

      # Whether the effects half of a restored snapshot permits reuse. Collection off is vacuously true —
      # the session keeps no collections, writes none, and the pre-#382 reuse decision stands unchanged.
      def effects_reuse_permitted?(payload)
        !@configuration.effects_enabled? || effect_collections_reusable?(payload)
      end

      # ADR-103 WD13 / #382 — whether a restored payload's effect collections may be served this run:
      # collection is on, and they were collected under the identity this run computes. Collection being
      # OFF answers false and costs nothing — the session then keeps no collections, writes none, and is
      # the pre-#382 session in every observable way.
      def effect_collections_reusable?(payload)
        return false unless @configuration.effects_enabled?
        return false if payload.effects_identity.nil? || !payload.effect_collections.is_a?(Hash)

        payload.effects_identity == current_effects_identity
      end

      # The effects identity for THIS run, memoised: it digests a YAML catalogue and the `effects:` block,
      # and a recheck asks for it on both the restore and the absorb side. nil when collection is off, so a
      # non-collecting run never loads the catalogue at all.
      #
      # **Deliberately plugin-blind**, unlike the ADR-45 whole-run effects slot, whose descriptor carries
      # {Effects::PluginFacts#digest} (#387). The two sides of this comparison sit on opposite sides of the
      # run: the restore asks before any plugin is loaded and the save asks after, so folding the plugin
      # facts in here would compare a blind digest against a sighted one and miss every single time. The
      # bound it leaves — a plugin upgrade that moves a row does not invalidate an `--incremental`
      # snapshot's effect collections — is recorded in `docs/internal-spec/effect-summaries.md`; the
      # primary (whole-run) path has no such hole, and `--incremental` is opt-in.
      def current_effects_identity
        return nil unless @configuration.effects_enabled?

        @current_effects_identity ||= Effects::Identity.digest(configuration: @configuration)
      end

      # The same Marshal-clean guard {#marshal_safe_return_summaries} applies, for the same reason: a
      # snapshot save must never raise. A dropped collection makes that file's summaries absent from the
      # next run's merged table, which understates its effects — so it is dropped only when it genuinely
      # will not serialise, and {FileCollection} is built to (the fork pool marshals one per file already).
      def marshal_safe_effect_collections
        return {} unless @configuration.effects_enabled?

        @effect_collections.each_with_object({}) do |(path, collection), safe|
          Marshal.dump(collection)
          safe[path] = collection
        rescue StandardError
          next
        end
      end

      # ADR-89 WD2 — the return summaries filtered to Marshal-clean entries. A summary's `keys` hold live
      # `Type` objects; the common carriers (Nominal, Constant, Union, shapes, Dynamic) Marshal, but a type
      # holding a live AST node would raise and abort the WHOLE snapshot save (a cache must never break a
      # run). Drop any entry that does not round-trip, so the snapshot always writes; a dropped entry just
      # means that callee's dependents always re-check (the conservative direction).
      def marshal_safe_return_summaries
        @return_summaries.each_with_object({}) do |(key, summary), safe|
          Marshal.dump(summary)
          safe[key] = summary
        rescue StandardError
          next
        end
      end

      # ADR-67 WD6c lift — the param table filtered to Marshal-clean entries, the same guard (and reason) as
      # {#marshal_safe_return_summaries} above. A dropped entry re-appears as "added" in the next recheck's
      # diff, so its callee re-checks — the conservative direction.
      def marshal_safe_param_table
        @param_table.each_with_object({}) do |(key, params), safe|
          Marshal.dump(params)
          safe[key] = params
        rescue StandardError
          next
        end
      end

      # Fold a #recheck's fresh results back into the cache + graph so the session is correct across
      # multiple edits: the analyzed set gets fresh diagnostics + digests + dependency edges, removed files
      # are evicted from every map, and the analyzed-file list advances to `current`.
      def absorb(runner, current, analyze_set, removed)
        @last_runner = runner # ADR-88 WD1 — the post-hoc fact-surface fingerprint reads this prepared registry.
        removed.each { |path| forget(path) }
        @analyzed = current
        # ADR-85 WD2 — the recheck's discovery folded the restored bundles and refreshed them (changed files
        # re-walked, removed files dropped, added files built), so adopt the runner's current set wholesale,
        # stamping the re-walked ones with their source-RBS digest (issue #1536).
        whole_project = current.all? { |path| analyze_set.include?(path) }
        @seed_bundles = source_rbs_gate.stamp(runner.seed_bundles, whole_project: whole_project)
        fresh_by_file = per_file(runner.per_file_diagnostics)
        # Issue #1553 — a re-analysed file's reads are this run's: a read it no longer makes stops guarding it.
        fresh_reads = plugin_reads_of(runner, analyze_set)
        analyze_set.each do |path|
          @cache[path] = fresh_by_file[path] || []
          @digests[path] = pack_digest(path)
          fresh_reads.key?(path) ? @plugin_reads[path] = fresh_reads[path] : @plugin_reads.delete(path)
        end
        @plugin_disclosures.absorb(runner.analysis_disclosures, analyze_set, @stale_disclosures)
        @stale_disclosures = Set.new
        forget_unbound_digests
        absorb_dependency_graph(runner)
        # Issues #796 / #794 — the recheck's own snapshots already carry the replayed rows folded together
        # with anything its closure demanded for itself, so this is the same union the next run replays.
        @run_level_rows = runner.run_level_rows
        refresh_return_summaries(runner, analyze_set)
        refresh_effect_collections(runner, analyze_set)
      end

      # ADR-103 WD13 / #382 — the effects analogue of {#refresh_return_summaries}, and the same soundness
      # order: drop every re-analyzed file's collection first, then fold this run's harvest in. A file the
      # recheck did NOT analyze keeps the collection the snapshot carried, which is exactly the reuse the
      # slot exists for; a re-analyzed file that produced nothing (a parse failure, a file of constants)
      # correctly ends up with nothing rather than with its pre-edit summaries.
      def refresh_effect_collections(runner, analyze_set)
        return unless @configuration.effects_enabled?

        analyzed = analyze_set.to_set
        @effect_collections.reject! { |path, _| analyzed.include?(path) }
        @effect_collections.merge!(runner.effect_collections_by_path)
        @effects_identity = current_effects_identity
        @effect_plugin_digest = effect_plugin_digest_of(runner)
      end

      # ADR-89 WD2 — replace the behavioural summaries of every re-analyzed file with THIS run's harvest: drop
      # the analyzed files' old summaries first, then fold the fresh ones. Dropping first is the soundness
      # invariant — a summary for a file is valid only if it came from a run that analyzed that file. On the
      # sequential path (the default + `--verify-incremental`) the harvest is complete, so a re-analyzed def's
      # summary is simply refreshed. On a pooled recheck the callee bodies are evaluated in worker processes,
      # so the main-process memo harvest is sparse; dropping first means a re-analyzed file with no fresh
      # summary loses its stale one (WD2 then conservatively re-checks its dependents) rather than comparing a
      # later edit against a pre-edit summary. Files NOT re-analyzed keep their (unchanged, valid) summaries.
      # A def whose symbol dependents WD2 skipped is observed under fewer keys, so its refreshed summary may
      # shrink — sound (fewer keys = more conservative) and self-correcting (an empty summary stops the gate
      # firing, so the callers re-analyse and repopulate).
      def refresh_return_summaries(runner, analyze_set)
        analyzed = analyze_set.to_set
        @return_summaries.reject! { |(path, _symbol), _| analyzed.include?(path) }
        @return_summaries.merge!(runner.return_summaries)
      end

      # Evict a removed file from every per-file map so its stale diagnostics are never served and it drops
      # out of the inverted dependency indexes.
      def forget(path)
        @cache.delete(path)
        @digests.delete(path)
        @sources.delete(path)
        @plugin_reads.delete(path)
        @plugin_disclosures.forget(path) # Unpinned hygiene: a removed file is never served, so never replayed.
        @symbol_sources.delete(path)
        @ancestry_sources.delete(path)
        @missing.delete(path)
        @symbol_fingerprints.delete(path)
        # ADR-89 WD2 — drop every behavioural summary a removed file provided (keys are `[path, symbol]`).
        @return_summaries.reject! { |(summary_path, _symbol), _| summary_path == path }
        # ADR-103 WD13 / #382 — and its effect collection, so a deleted file stops contributing summaries
        # and edges to the merged table the fixpoint closes.
        @effect_collections.delete(path)
        # @class_decls is wholesale-replaced from the (removed-excluding)
        # pre-pass in absorb_dependency_graph, and is frozen, so no delete.
      end

      # Fold a runner's dependency recording (file-level and symbol-level) back into the session's graph
      # state. Rebuilds all derived indexes.
      def absorb_dependency_graph(runner)
        runner.file_dependencies.each do |path, record|
          @sources[path] = record.sources.dup
          @symbol_sources[path]   = record.symbol_sources.transform_values(&:dup)
          @ancestry_sources[path] = record.ancestry_sources.dup
          @missing[path]          = record.missing.dup
        end
        @dependents          = Incremental.invert(@sources)
        @symbol_dependents   = Incremental.invert_symbols(@symbol_sources)
        @ancestry_dependents = Incremental.invert(@ancestry_sources)
        @negative_dependents = Incremental.invert(@missing)
        @symbol_fingerprints.merge!(runner.symbol_fingerprints)
        # Wholesale replace (the subset runner's pre-pass is complete): a file that lost its last class must
        # drop out of the map so a later re-add registers as an appearance.
        @class_decls = runner.class_declarations
        @constant_decls = runner.constant_declarations
      end

      # Per-symbol body fingerprints from the pre-parsed `index` (the shared scan-summary def-index — Prism
      # parse + def extraction, no type inference). Returns `{ path => { "ClassName#method" => sha256_hex } }`
      # with singleton methods under `"Class.method"` keys. Used by {#recheck} to detect which symbols in a
      # changed file actually changed, so only their callers are added to the affected closure.
      def symbol_fingerprints_from_index(index)
        return {} if index.nil?

        result = Hash.new { |h, k| h[k] = {} }
        fold_symbol_fingerprints(result, index[:def_sources], index[:def_nodes], "#")
        # ADR-46 slice 4 (singleton) — mirror the instance fold over the singleton tables so a `def self.x`
        # body edit yields a changed `"Class.method"` pair, matching the `Runner#symbol_fingerprints` key that
        # the recorded singleton symbol edges (`singleton_def_for`) invert against.
        fold_symbol_fingerprints(result, index[:singleton_def_sources], index[:singleton_def_nodes], ".")
        result.transform_values(&:freeze).freeze
      end

      # Folds one `(sources, nodes)` table pair from the re-parse index into `result` under `separator`
      # (`#` instance / `.` singleton). Nodes here are always LIVE (a fresh parse of the changed paths), so
      # the fingerprint is the def's source slice; `sources` supplies the `"path:line"` a `Prism::Location`
      # hides.
      def fold_symbol_fingerprints(result, sources, nodes, separator)
        sources.each do |class_name, methods|
          methods.each do |method_sym, path_line|
            path = path_line.split(":", 2).first
            node = nodes.dig(class_name, method_sym)
            next unless node

            result[path]["#{class_name}#{separator}#{method_sym}"] = Digest::SHA256.hexdigest(node.location.slice)
          end
        end
      end

      # ADR-46 slice 3 — the consumers to re-check because a symbol that appeared in a changed file resolves
      # a prior missed lookup, and (issue #639) because a class DECLARATION appeared or vanished. Maps each
      # appeared `"ClassName#method"` to the negative-dependency key it would satisfy (`toplevel:foo` for a
      # top-level def, `method:C#m` otherwise), then unions the recorded negative-dependents of those keys.
      # Issue #1120 — plus the consumers of any refinement name the edit moved ({#refinement_affected}). Issue #1367 —
      # and every file whose last result holds a `global.*` diagnostic ({#global_write_reporters}). Issue #1459 — and
      # the consumers of any method name a file started or stopped defining ({#defined_name_affected}). Issue #2134 —
      # and the consumers of any visibility slot a file moved ({#visibility_name_affected}).
      def negative_affected(changed, removed, new_fingerprints, new_class_decls, new_constant_decls, summary = nil)
        appeared_methods = Incremental.appeared_symbols(changed, @symbol_fingerprints, new_fingerprints)
        # Issue #639 — a class DISAPPEARING satisfies the `class:` kind too, now that a resolved bare
        # reference records the edge and not only a failed one; removed files join the diff for it.
        moved_classes = Incremental.changed_class_declarations(
          changed + removed, @class_decls, new_class_decls
        )
        # Issue #644 — a constant whose PUBLICATION moved satisfies the `constant:` kind, keyed on the same
        # last segment the consumer recorded. Removed files join this diff (as they do the class one above):
        # deleting a second declarer restores the precise answer, and no other producer input can see that.
        moved_constants = Incremental.changed_constant_publications(
          changed + removed, @constant_decls, new_constant_decls
        )
        keys = appeared_methods.map { |symbol| negative_key_for(symbol) }
        keys.concat(class_move_keys(moved_classes))
        keys.concat(moved_constants.map { |name| "constant:#{name.split('::').last}" })
        Incremental.negative_closure(keys, @negative_dependents) | table_diff_affected(changed + removed, summary) |
          global_write_reporters
      end

      # The consumers of the name-keyed edges whose producers diff a per-file table between each file's seed bundle
      # and the scan.
      def table_diff_affected(paths, summary)
        refinement_affected(paths, summary) | defined_name_affected(paths, summary) |
          visibility_name_affected(paths, summary) | mark_affected(paths, summary) |
          global_census_affected(paths, summary)
      end

      # Issue #1833 — the consumers whose answer read a class mark that moved in this edit. A reader of a class's
      # envelope bucket records `mark:<last segment>` (`Scope#parameter_envelopes_of`), whichever way it answered, so
      # a file that adds or drops only a mark (`x.singleton_class.prepend(Comparable)`, `o.extend(Helper)` in a
      # method body, a `refine` block's refined mark) re-checks it although the file declares nothing it read. A
      # reader that scans every bucket for an object-extended module (`SourceArity#object_extension_may_shadow?`)
      # records `mark:*`, which fires when an object-extended mark moves. The before-state is each touched file's
      # seed bundle, the after-state the scan's merged table.
      #
      # Issue #1661 — and `mixin:<qualified name>` for a class or module whose unpositioned mixin edges moved
      # ({Incremental.changed_unpositioned_owners}): an external chain entry records it for each name it can denote
      # (`ResolutionChain#record_hooks`), so a new file that taints `Comparable` with `include(*MODS)` re-checks the
      # readers of a chain through it. It is not `mark:`, which a plain reopening of a module moves (the bucket's
      # module mark) and which would re-check every reader of `Kernel` on any `module Kernel` reopening.
      def mark_affected(paths, summary)
        def_index = summary && summary[:def_index]
        before = paths.map { |path| @seed_bundles.dig(path, :parameter_envelopes) }
        moved = Incremental.changed_class_marks(before, [def_index && def_index[:parameter_envelopes]])
        tainted = Incremental.changed_unpositioned_owners(
          paths.map { |path| @seed_bundles.dig(path, :unpositioned_mixins) },
          [def_index && def_index[:unpositioned_mixins]]
        )
        return Set.new if moved.empty? && tainted.empty?

        keys = moved.map { |(class_name, _mark)| "mark:#{class_name.split('::').last}" }.uniq
        keys.concat(mixin_keys(tainted))
        extended = Scope::DiscoveryIndex::ENVELOPE_OBJECT_EXTENDED_MARK
        keys << "mark:*" if moved.any? { |(_class_name, mark)| mark == extended }
        Incremental.negative_closure(keys, @negative_dependents)
      end

      # Issue #1661 — the `mixin:` keys an owner of a moved unpositioned edge fires. The table keys a receiver-form
      # owner by the spelling written (`class File; Constants.include(*MODS); end` is `"Constants"`), not the constant
      # Ruby resolves it to, while the chain files the qualified candidate (`mixin:File::Constants`). The table does
      # not carry the nesting, and every lexical-prefix candidate of the owner ends in `::<owner>`, so the owner fires
      # its own key and every recorded `mixin:` key ending in `::<owner>`. A relative spelling over-fires to the
      # readers of every module sharing its trailing segments; a qualified one fires only its suffix matches.
      def mixin_keys(owners)
        keys = owners.map { |name| "mixin:#{name}" }
        suffixes = owners.map { |name| "::#{name}" }
        @negative_dependents.each_key do |key|
          keys << key if key.start_with?("mixin:") && suffixes.any? { |suffix| key.end_with?(suffix) }
        end
        keys.uniq
      end

      # The negative keys a class-declaration diff fires: `class:<last segment>` for a class name, and (issue #1820)
      # `subclass_of:<last segment of the superclass>` for a `[class, superclass]` pair appearing or vanishing. Any
      # class declaration moving may move the set of classes whose superclass the tables do not know, which
      # `subclass_of:*` stands for.
      def class_move_keys(moved)
        names, edges = moved.partition { |entry| entry.is_a?(String) }
        keys = names.map { |klass| "class:#{klass.split('::').last}" }
        keys.concat(edges.map { |(_child, parent)| "subclass_of:#{parent.split('::').last}" })
        keys << "subclass_of:*" unless moved.empty?
        keys
      end

      # Issue #1120 — the consumers whose `call.undefined-method` answer read the refinement table for a method
      # name whose refinements moved in this edit. The before-state is each file's seed bundle (the per-file
      # table the last run recorded), the after-state the scan's per-file tables. A refine body is not a class's
      # method, so neither the symbol fingerprints nor the appeared-symbol diff above sees it.
      def refinement_affected(paths, summary)
        after = (summary && summary[:refinements]) || {}
        before = paths.to_h { |path| [path, @seed_bundles.dig(path, :refinements)] }
        names = Incremental.changed_refinement_names(paths, before, after)
        return Set.new if names.empty?

        Incremental.negative_closure(names.map { |name| "refinement:#{name}" }, @negative_dependents)
      end

      # Issue #1459 — the consumers whose answer asked whether the program defines a method name anywhere, for each
      # name a file in `paths` started or stopped defining. The before-state is each file's seed bundle, the
      # after-state the scan's per-file name sets. Unlike the appeared-symbol diff, it sees a name an `attr_*`,
      # `alias` or `define_method` adds, and one that vanishes, which brings a declined reading back.
      def defined_name_affected(paths, summary)
        after = (summary && summary[:defined_method_names]) || {}
        before = paths.to_h do |path|
          bundle = @seed_bundles[path]
          [path, bundle && Inference::ScopeIndexer.defined_method_names(bundle)]
        end
        names = Incremental.changed_defined_names(paths, before, after)
        return Set.new if names.empty?

        Incremental.negative_closure(names.map { |name| "defines:#{name}" }, @negative_dependents)
      end

      # Issue #2158 — the consumers whose `global.*` write rule read a census entry that a file in `paths` started or
      # stopped writing. The before-state is each file's seed bundle, the after-state the scan's per-file census. The
      # write the census silenced reports nothing, so {#global_write_reporters} does not reach it.
      def global_census_affected(paths, summary)
        after = (summary && summary[:global_write_census]) || {}
        before = paths.to_h { |path| [path, @seed_bundles.dig(path, :global_write_census)] }
        keys = Incremental.changed_global_census_keys(paths, before, after)
        return Set.new if keys.empty?

        Incremental.negative_closure(keys, @negative_dependents)
      end

      # Issue #2134 — the consumers whose answer read a class's visibility slot for a method, or its contest, for each
      # slot whose entries a file in `paths` added, dropped or changed (`Scope#discovered_method_visibility`). The
      # before-state is each file's seed bundle, the after-state the scan's per-file entries. A `private :foo` in a
      # reopening or a `class_eval` block moves no `def`, so neither the symbol fingerprints nor the defined-name diff
      # sees it.
      def visibility_name_affected(paths, summary)
        after = (summary && summary[:visibility_entries]) || {}
        before = paths.to_h do |path|
          bundle = @seed_bundles[path]
          [path, bundle && Inference::ScopeIndexer.visibility_entries(bundle)]
        end
        slots = Incremental.changed_visibility_slots(paths, before, after)
        return Set.new if slots.empty?

        Incremental.negative_closure(slots.map { |slot| "visibility:#{slot}" }, @negative_dependents)
      end

      # The qualified class/module names declared in the pre-parsed `index` (shared with
      # {#symbol_fingerprints_from_index}, so the changed set is parsed once). `{ path => Set<class name> }`.
      def class_declarations_from_index(index)
        return {} if index.nil?

        result = Hash.new { |hash, key| hash[key] = Set.new }
        [index[:class_sources], index[:singleton_class_sources] || {}].each do |sources|
          sources.each { |class_name, files| files.each { |file| result[file] << class_name } }
        end
        Incremental.add_superclass_edges(result, index[:class_sources], index[:superclasses])
        result.transform_values(&:freeze).freeze
      end

      # Issue #644 — the per-file PUBLICATION CENSUS of the pre-parsed `index`:
      # `{ path => { constant name => descriptor } }`, the twin of {#class_declarations_from_index}. The
      # descriptor is what the diff compares — see {Incremental.changed_constant_publications} for why a bare
      # name set cannot answer the question.
      def constant_declarations_from_index(index)
        return {} if index.nil?

        result = Hash.new { |hash, key| hash[key] = {} }
        index[:constant_writes].each do |name, by_path|
          by_path.each { |path, descriptor| result[path][name] = descriptor }
        end
        result.transform_values(&:freeze).freeze
      end

      # ADR-89 WD2 — the (live, freshly parsed) def node for a `"Class#method"` / `"Class.method"` symbol in
      # the changed-set scan index, or nil. Instance methods live under `def_nodes`, singleton under
      # `singleton_def_nodes`, both keyed by class name then method Symbol.
      def scan_def_node(symbol, scan_index)
        singleton = !symbol.include?("#")
        class_name, method_name = symbol.split(singleton ? "." : "#", 2)
        return nil if method_name.nil?

        table = singleton ? scan_index[:singleton_def_nodes] : scan_index[:def_nodes]
        table.dig(class_name, method_name.to_sym)
      end

      # ADR-89 WD2 — true when the ONLY cross-file body surfaces of `node` a symbol dependent can consume are
      # its return type and its content-mutation effects — so comparing exactly those two is a COMPLETE
      # behavioural check. A def qualifies when its body writes no instance / class variable (an ivar
      # definite-assignment a same-class caller consumes), does not `yield` (a block-parameter surface a
      # caller passing a block consumes), and makes no implicit-self call (which could carry a transitive
      # shared-state write). Deliberately conservative + purely syntactic: a def with a self-call or a
      # shared-state write keeps its dependents (the general all-surfaces gate is deferred). Excludes nested
      # `def`s (a different self) but walks blocks / lambdas (same self).
      def gate_eligible_def?(node)
        return false if node.nil? || !node.respond_to?(:body) || node.body.nil?

        !body_has_ineligible_node?(node.body)
      end

      def body_has_ineligible_node?(node)
        return false if node.nil? || node.is_a?(Prism::DefNode)

        return true if INELIGIBLE_GATE_NODES.any? { |kind| node.is_a?(kind) }
        return true if self_dispatch_call?(node)

        node.rigor_each_child { |child| return true if body_has_ineligible_node?(child) }
        false
      end

      def self_dispatch_call?(node)
        node.is_a?(Prism::CallNode) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
      end

      # ADR-89 WD2 — node kinds whose presence in a def body means a caller may consume a body surface beyond
      # return + content-mutation: any instance/class-variable write (ivar definite-assignment) and `yield`
      # (block-parameter typing). Class variables are per-file (never seeded cross-file) but are included for
      # a conservative margin; global writes are likewise per-file so are not listed.
      INELIGIBLE_GATE_NODES = [
        Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableOperatorWriteNode,
        Prism::ClassVariableWriteNode, Prism::ClassVariableOrWriteNode,
        Prism::ClassVariableAndWriteNode, Prism::ClassVariableOperatorWriteNode,
        Prism::YieldNode
      ].freeze
      private_constant :INELIGIBLE_GATE_NODES

      # ADR-89 WD2 — true when the current content-mutation effect set of `pair`'s (edited) def equals the one
      # persisted in its return summary. Computed session-side from the fresh node (pure AST — no scope), so a
      # caller's arg flooring is proven unchanged before the return re-evaluation. A nil / raised computation
      # reads as CHANGED (keeps the pair).
      def effects_unchanged?(pair, scan_index)
        node = scan_def_node(pair.last, scan_index)
        return false if node.nil?

        current = content_effects_for(node)
        !current.nil? && current == (@return_summaries[pair][:effects] || [])
      end

      def content_effects_for(node)
        (@effects_evaluator ||= Inference::StatementEvaluator.new(scope: Scope.empty))
          .content_mutated_parameter_positions(node)
      rescue StandardError
        nil
      end

      # ADR-89 WD2 — the subset of `pairs` whose (edited) def re-evaluates to the SAME return descriptor at
      # every persisted key. Runs one runner probe (`evaluate_return_types` — builds the discovery + env once,
      # no file analysis) over all candidate defs, then keeps a pair only when every key's re-evaluated
      # descriptor is present (not a memo refusal) and equal to the persisted one. A probe failure yields an
      # empty set (keep everything).
      def return_stable_pairs(pairs, scan_index)
        specs = pairs.filter_map { |pair| return_spec_for(pair, scan_index) }
        return Set.new if specs.empty?

        results = probe_return_types(specs)
        specs.each_with_object(Set.new) do |spec, stable|
          descriptors = results[[spec[:class_name], spec[:method_name], spec[:singleton]]]
          expected = @return_summaries[spec[:pair]][:returns]
          next if descriptors.nil? || descriptors.length != expected.length
          next unless descriptors.each_with_index.all? { |d, i| !d.nil? && d == expected[i] }

          stable << spec[:pair]
        end
      end

      def return_spec_for(pair, scan_index)
        path, symbol = pair
        node = scan_def_node(symbol, scan_index)
        return nil if node.nil?

        singleton = !symbol.include?("#")
        class_name, method_name = symbol.split(singleton ? "." : "#", 2)
        { pair: pair, path: path, class_name: class_name, method_name: method_name.to_sym,
          singleton: singleton, keys: @return_summaries[pair][:keys] }
      end

      def probe_return_types(specs)
        build_runner.evaluate_return_types(@paths, specs)
      rescue StandardError
        {}
      end

      TOP_LEVEL_KEY = Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY
      private_constant :TOP_LEVEL_KEY

      def negative_key_for(symbol)
        class_name, method = symbol.split("#", 2)
        class_name == TOP_LEVEL_KEY ? "toplevel:#{method}" : "method:#{symbol}"
      end

      def build_runner(**)
        Runner.new(
          configuration: @configuration, cache_store: @cache_store, environment: @environment,
          plugin_requirer: @plugin_requirer, seed_bundles: @seed_bundles, collect_seed_bundles: true,
          workers: @workers, buffer: @buffer, explain: @explain, on_file_indexed: @on_file_indexed, **
        )
      end

      # The forced targets present in `current`, and the recheck's analyse set with them joined to the closure.
      def forced_analyze_set(affected, current)
        forced = @force_targets & current.to_set
        [forced, (affected | forced) & current]
      end

      # What the session serves a narrowed run for the files it does not analyse: their cached per-file rows (#1524),
      # and (#1898) their effect collections, so the run closes its effect graph over the whole project.
      def served_state(reused)
        { served_per_file_diagnostics: @cache.slice(*reused),
          served_effect_collections: @effect_collections.slice(*reused),
          served_run_disclosures: @plugin_disclosures.served(reused, @stale_disclosures) }
      end

      # Issue #2020 — the run-scoped plugin rows whose reads went stale ({RunDisclosureLedger}): one registering file
      # each joins the closure, and their replays are withheld until {#absorb} refreshes them from that file.
      def disclosure_refreshers(removed)
        @stale_disclosures = @plugin_disclosures.stale_identities { |row| plugin_read_fresh?(row) }
        @plugin_disclosures.refreshers(@stale_disclosures, removed.to_set)
      end

      # Issue #1898 — the plugin effect-fact digest a run's collections were stamped under. A plugin writes its
      # attributions and edges into a file's collection when the file is collected, and what it contributes can
      # follow project state no file digest sees (rigor-activejob reads `config.active_job.queue_adapter`), so a
      # served collection is current only while this digest is. nil when collection is off.
      def effect_plugin_digest_of(runner)
        @configuration.effects_enabled? ? runner.effect_plugin_facts.digest : nil
      end

      # Whether `runner` judged envelopes over served collections stamped under a different plugin effect-fact
      # digest, or an unknown one. The comparison waits for the run because the plugins load inside it.
      def served_effects_stale?(runner, reused)
        return false if reused.empty? || @effect_collections.empty?

        effect_plugin_digest_of(runner) != @effect_plugin_digest
      end

      # The answer {#recheck} gives when {#served_effects_stale?}: a full baseline, reported as a recheck that
      # re-analysed every file. {#run_incremental} reads `rebaselined` so it neither runs a second baseline
      # nor reports the run as warm.
      def rebaseline_recheck(changed, added, removed)
        diagnostics = baseline
        recheck_result(diagnostics, [changed, added, removed],
                       affected: @analyzed.to_set, reused: Set.new, runner: @last_runner, rebaselined: true)
      end

      # A {Recheck} over `deltas` (`[changed, added, removed]`), counting `runner`'s template units.
      def recheck_result(diagnostics, deltas, affected:, reused:, runner:, rebaselined: false, stale_readers: Set.new)
        changed, added, removed = deltas.map(&:to_set)
        Recheck.new(diagnostics: diagnostics, changed: changed, added: added, removed: removed, affected: affected,
                    stale_readers: stale_readers,
                    reused: reused, templates: runner.template_unit_paths.size, rebaselined: rebaselined)
      end

      # A recheck that forces targets analyses in this process, so the index callback reaches them.
      def forced_target_options(forced)
        forced.empty? ? {} : { workers: 0 }
      end

      # Run the runner over the session's explicit paths (or, when none were given, the configuration's
      # `paths:` via `Runner#run`'s default).
      def run_runner(runner)
        @paths ? runner.run(@paths) : runner.run
      end

      # Group the runner's PER-FILE diagnostics by path, keeping only analyzed project files.
      #
      # The argument is `Runner#per_file_diagnostics` — what `PoolCoordinator#analyze_files` returned, already
      # severity-resolved as the run's stream is (this cache serves reused files without re-stamping, so a
      # raw row would resurrect an `:off` rule and lose every override) — never the run's full stream. Every
      # run-level row is regenerated by every run and must not be served
      # from this cache, and "run-level" is a property of where a row was PRODUCED, not of where it is
      # positioned: the `.rigor.yml` rows the slice below drops are the common case, but
      # `effect.annotations-unchecked` sits at the first annotated file and the two `source-rbs-*` rows sit
      # at the source file that carried the annotation, and all three are produced once per run off the
      # environment and its reporters. Slicing the full stream cached them, and once a narrowed run's
      # environment carried the whole project's synthesized RBS (#793) each was regenerated for a file the
      # recheck did not analyse and met its cached twin in the merge — two rows, `--verify-incremental` red,
      # on the default configuration with the bundled rbs-inline plugin (#788 rounds 5 and 6; a rule-id
      # denylist missed the second pair). Feeding only the per-file stream makes the split structural.
      def per_file(diagnostics)
        diagnostics.group_by(&:path).slice(*@analyzed)
      end

      # ADR-87 WD1 — change detection over the candidate paths (files present in both the prior and current
      # analyzed set). A candidate is UNCHANGED when its recorded stat entry ({#pack_digest}) validates via
      # {Cache::FileDigest.stat_fresh?}: the file is stat-ed first and re-hashed ONLY when its
      # `(size, mtime, ctime, inode)` tuple moved or the entry is racy — so an unchanged file hashes zero
      # content bytes (the recon anomaly this closes: the old path SHA-256'd every file every recheck). A
      # touch (moved stat, identical content) re-hashes once and validates fresh. Returns the changed subset.
      def changed_paths(candidates)
        candidates.reject { |path| stat_fresh?(path) }
      end

      def buffer_path?(path)
        !@buffer.nil? && path == @buffer.logical_path
      end

      # Editor mode (#146) — the bound buffer's logical path is fresh exactly when the EDITOR's bytes still
      # hash to the digest the snapshot recorded for the file they stand in for. The recorded stat tuple
      # describes the file on disk, which an edit in the editor never moves, so validating through it serves
      # the editor its own pre-buffer answers (#960); hashing the buffer makes the substituted file changed
      # whenever it differs, and keeps an untouched buffer out of the closure. Anything unreadable or
      # unrecorded reads as changed, the conservative direction the rest of this tier takes.
      def buffer_fresh?(path)
        recorded = Cache::FileDigest.content_digest(@digests[path])
        return false if recorded.nil?

        Cache::FileDigest.hexdigest(@buffer.resolve(path)) == recorded
      rescue StandardError
        false
      end

      # Editor mode (#146 / #960) — `--instead-of` is spelled the way the editor spells it (absolute, or
      # `./`-prefixed), while the analysed set is spelled the way the run's path arguments produce. A binding
      # whose logical path matches no member of that set substitutes nothing at all: every reader keeps
      # reading the file on disk and the run answers as if no buffer had been passed. Re-spell the binding
      # onto the set's own member, identified by real path, once the set is known.
      def rebind_buffer(files)
        return if @buffer.nil? || files.include?(@buffer.logical_path)

        target = BufferBinding.real_path(@buffer.logical_path)

        match = files.find { |path| BufferBinding.real_path(path) == target }
        @buffer = BufferBinding.new(logical_path: match, physical_path: @buffer.physical_path) if match
      end

      # True when `path`'s recorded stat entry proves it unchanged since the last analysis. Any stat / parse
      # failure (missing entry, unreadable / vanished file) reads as NOT fresh (→ re-analyse), preserving the
      # prior `digest(path) != recorded` "changed" semantics for a file that cannot be validated.
      def stat_fresh?(path)
        return buffer_fresh?(path) if buffer_path?(path)

        entry = @digests[path]
        return false if entry.nil?

        Cache::FileDigest.stat_fresh?(path, entry)
      rescue StandardError
        false
      end

      # ADR-87 WD1 — the recorded freshness entry for `path`: its SHA-256 content digest packed with the stat
      # tuple `(size, mtime_ns, ctime_ns, inode)` and the run's recording instant, so the NEXT recheck can
      # validate it by a single `File::Stat` when the tuple has not moved. The SHA-256 digest stays the sole
      # change authority — the stat tuple only decides whether it must be recomputed. "missing" when the file
      # cannot be read / stat-ed (its prior sentinel, so a vanished file still compares unequal and re-analyses).
      def pack_digest(path)
        Cache::FileDigest.pack_stat(path, Cache::FileDigest.hexdigest(path)) || "missing"
      rescue StandardError
        "missing"
      end
    end
  end
end
