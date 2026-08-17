# frozen_string_literal: true

require "digest"
require_relative "incremental"
require_relative "plugin_fact_fingerprint"
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
    # byte-identical (as a sorted set) to a full `--no-cache` re-analysis of the edited tree. This is the
    # `--verify-incremental` acceptance gate, here without disk persistence or CLI wiring (the cache is
    # in-process). It models the body tier only: an edit that adds / removes / moves a *file* is outside
    # the analyzed set it maintains and falls to a fresh {#baseline} (the structural tier is a later slice).
    # The class-length budget is relaxed: this is one cohesive orchestrator of the incremental state
    # (per-file diagnostics cache, the file-level / symbol-level / negative dependency graphs, and the ADR-85
    # seed bundles), clearer read together than split across micro-classes that would all share the same ivars.
    class IncrementalSession # rubocop:disable Metrics/ClassLength
      # The outcome of a {#recheck}: the merged diagnostics plus the file sets, so a caller (or the verify
      # gate) can report what was re-analyzed versus served from cache. `added` / `removed` carry the
      # structural delta so {#run_incremental} (ADR-87 WD3) can recognise a zero-change recheck and skip the
      # unconditional snapshot rewrite.
      Recheck = Data.define(:diagnostics, :changed, :added, :removed, :affected, :reused) do
        # A recheck that changed, added, and removed nothing — the session state is byte-equivalent to the
        # snapshot that was restored, so persisting it again would only rewrite identical bytes.
        def no_change?
          changed.empty? && added.empty? && removed.empty?
        end
      end

      # @param paths [Array<String>, nil] explicit analysis roots; nil (the default) uses the configuration's
      #   `paths:`.
      # @param environment [Rigor::Environment, nil] optional shared environment to thread into each internal
      #   Runner. Long-lived callers and specs can use this to avoid rebuilding the same RBS universe for
      #   every baseline / recheck / oracle run.
      # @param cache_store [Rigor::Cache::Store, nil] ADR-85 WD1 — the persistent cache each internal Runner
      #   exposes to the RBS-env and plugin-producer tiers. A cross-process `--incremental` recheck otherwise
      #   rebuilt a fresh runner with no store, so every plugin `#prepare` producer (the ADR-9/#74/ADR-60 WD3
      #   record-and-validate caches) recomputed per invocation — 86% of a Rails warm incremental. Threading
      #   the store lets those producers serve from disk. `nil` (the default) preserves the pre-#85 behaviour
      #   the specs assert; the whole-run ADR-45 result cache stays disabled on these runs
      #   (`Runner#run_result_cacheable?` excludes `record_dependencies` / `analyze_only`).
      # @param plugin_requirer [#call, nil] optional gem-require hook threaded into each internal Runner
      #   (mirrors {Runner}'s parameter). nil (the default, and what the CLI passes) uses `Kernel.require`;
      #   embedders and specs inject a fake so a test plugin registers without touching the real load path.
      # @param workers [Integer] ADR-46 — the resolved fork-pool worker count threaded into every internal
      #   analyzer, so a `--incremental` recheck's closure re-analysis parallelises exactly like the standard
      #   `check` path (the recon's audit: `--workers` / `RIGOR_RACTOR_WORKERS` / `parallel.workers:` were
      #   silently ignored because `build_runner` passed no `workers:`). 0 (the default, and what the specs and
      #   `--verify-incremental` gate use) keeps the sequential recording path bit-for-bit unchanged. The fork
      #   pool records each worker's cross-file reads and marshals them back (PoolCoordinator), so the
      #   dependency graph a pooled recheck rebuilds equals the sequential one.
      def initialize(configuration:, paths: nil, environment: nil, cache_store: nil, plugin_requirer: nil,
                     workers: 0, buffer: nil)
        @configuration = configuration
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
        # ADR-85 WD2 — per-file discovery seed bundles keyed by logical path. A cold baseline builds them; a
        # warm recheck folds them (re-walking only changed files) and refreshes the set. Ride the snapshot.
        @seed_bundles = {}
        @cache = {}              # analyzed path => [Diagnostic]
        @sources = {}            # analyzed path => Set<source path it read from>
        @digests = {}            # analyzed path => ADR-87 packed stat-digest entry at last analysis
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
        reset_effect_state
        # ADR-88 WD1 — the plugin fact-surface digest computed for THIS invocation (nil until a
        # `#run_incremental` pass runs / a plugin-free project) and the reporting flags a caller (the CLI
        # banner + `--cache-stats`) reads after `#run_incremental`. `@last_runner` is the analysis runner the
        # post-hoc fingerprint reads from; `@plugin_fact_reusable` is the computed decision object.
        @plugin_fact_digest = nil
        @opaque_plugin_ids = [].freeze
        @fact_surface_invalidated = false
        @last_runner = nil
        @plugin_fact_reusable = nil
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
        runner = build_runner(record_dependencies: true)
        diagnostics = run_runner(runner).diagnostics
        @last_runner = runner # ADR-88 WD1 — the post-hoc fact-surface fingerprint reads this prepared registry.
        @analyzed = runner.analyzed_files
        @seed_bundles = runner.seed_bundles # ADR-85 WD2 — the freshly built bundle set for the next run.
        absorb_dependency_graph(runner)
        @return_summaries = runner.return_summaries # ADR-89 WD2 — the full-run behavioural surface.
        # ADR-67 WD6c lift — the seed table the runner's own pre-pass computed ({} when the gate is off).
        # Reading it back, rather than computing it here, keeps the baseline single-collect.
        @param_table = runner.param_inferred_types
        # ADR-103 WD13 / #382 — a baseline collects every file, so its collections are the whole world.
        @effect_collections = runner.effect_collections_by_path
        @effects_identity = current_effects_identity
        @cache = per_file(diagnostics)
        @digests = @analyzed.to_h { |path| [path, pack_digest(path)] }
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
        # ADR-67 WD6c lift — recompute the whole-project inferred-param table BEFORE deciding the closure,
        # and diff it against the snapshot's copy: an entry that moved (because a caller's argument type
        # changed, a caller appeared, or one vanished) invalidates the CALLEE's file and its symbol
        # dependents, none of which the file-digest tier can see (the callee's text is unchanged).
        fresh_params = fresh_param_table(current, changed, added, removed)
        param_files, param_pairs = param_seed_invalidation(fresh_params)
        affected = affected_closure(changed, added, removed, param_files, param_pairs)
        analyze_set = affected & current
        # The freshly collected table is handed to the runner so the run seeds from the SAME table the diff
        # was decided on (and the collector runs once per recheck, not twice).
        runner = build_runner(analyze_only: analyze_set, record_dependencies: true,
                              param_inferred_types: fresh_params)
        fresh = run_runner(runner).diagnostics
        @last_runner = runner # ADR-88 WD1 — the post-hoc fact-surface fingerprint reads this prepared registry.
        reused = (current & previous) - affected.to_a
        merged = fresh + reused.flat_map { |path| @cache[path] || [] }
        absorb(runner, fresh, current, analyze_set, removed)
        @param_table = fresh_params
        Recheck.new(diagnostics: merged, changed: changed.to_set, added: added.to_set,
                    removed: removed.to_set, affected: affected, reused: reused.to_set)
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
      def affected_closure(changed, added, removed, param_files = Set.new, param_pairs = Set.new)
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
        closure = base | changed.to_set | added.to_set | negative_affected(scan, new_fps, new_class_decls)
        closure = param_seed_closure(closure, param_files)
        removed.each { |path| closure |= @dependents[path] || Set.new }
        closure.freeze
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
      # unstable files + symbol deps of the changed pairs), else the coarse file-level fan-out.
      def dependents_base(unstable, symbol_pairs)
        if symbol_pairs.any? || unstable.any? { |f| @ancestry_dependents[f] }
          Incremental.affected_with_symbols(unstable, symbol_pairs, @symbol_dependents, @ancestry_dependents)
        else
          Incremental.affected(unstable, @dependents)
        end
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
      # unchanged. Falls back to treating EVERY changed file as unstable (today's full closure) when a
      # comment-ingesting plugin is loaded — such a plugin reads the very comments the signature ignores, so a
      # comment edit it treats as a no-op could change a cross-file type. Sorbet sigs / dry-types includes are
      # CODE, captured by ADR-88's plugin-fact fingerprint (WD3), so only comment-as-input plugins escape here.
      def declaration_unstable(changed, declaration_signatures)
        return changed if comment_ingesting_plugin_loaded?

        changed.reject { |path| declaration_stable?(path, declaration_signatures[path]) }
      end

      def declaration_stable?(path, current_declaration_signature)
        return false if current_declaration_signature.nil?

        bundle = @seed_bundles[path]
        return false if bundle.nil?

        bundle[:declaration_signature] == current_declaration_signature
      end

      def comment_ingesting_plugin_loaded?
        # Mirrors the plugin loader's gem-name resolution (`ProjectPrePasses#trusted_gem_name`): a String
        # entry IS the gem name; a Hash entry names it under `"gem"` (or the manifest `"id"`).
        @configuration.plugins.any? do |entry|
          name = entry.is_a?(Hash) ? (entry["gem"] || entry["id"]) : entry
          COMMENT_INGESTING_PLUGIN_IDS.include?(name.to_s)
        end
      end

      # The current project file set (cheap directory expansion, no analysis), used to detect files added /
      # removed since the last run.
      def current_files
        runner = build_runner
        @paths ? runner.analysis_file_set(@paths) : runner.analysis_file_set
      end

      # Verification engine (the `--verify-incremental` gate): with NO source edit, re-analyze `subset` fresh
      # and serve every other analyzed file from the baseline cache. Because nothing on disk changed, the
      # merged result MUST equal a full analysis — so this exercises the subset-analysis and cache-merge
      # paths against a known-good oracle (a full `--no-cache` run) for an arbitrary partition, without
      # mutating session state. Returns the merged diagnostics.
      def reanalyze_subset(subset)
        affected = subset.to_set
        # ADR-67 WD6c lift — seed the subset run from the baseline's own table so the verification engine
        # exercises the exact seeds the served cache entries were computed under (and skips a re-collect).
        runner = build_runner(analyze_only: affected, param_inferred_types: @param_table)
        fresh = run_runner(runner).diagnostics
        reused = @analyzed - affected.to_a
        fresh + reused.flat_map { |path| @cache[path] || [] }
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
        # ADR-87 WD1 — install the per-run digest table + recording instant + strict flag for the whole
        # invocation so change-detection's stat-then-digest freshness (`#pack_digest` / `#stat_fresh?`) honours
        # `cache.validation: digest` (and `RIGOR_STRICT_VALIDATION`, which the env-only path already sees) and
        # shares one digest memo across change detection and the baseline/absorb re-pack. The inner
        # `Runner#run` nests its own `with_run` for the analysis descriptors; nesting is safe (each restores).
        Cache::FileDigest.with_run(strict: @configuration.cache_validation_strict?) do
          restored = fingerprint && snapshot.load(fingerprint: fingerprint)
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
            if fact_reusable && effects_reusable
              diagnostics = result.diagnostics
              warm = true
              # ADR-87 WD3 — a warm recheck that changed nothing leaves the session state byte-equivalent to the
              # snapshot it restored, so skip the unconditional rewrite (209ms + 2 MB on gitlab per null recheck).
              # A cold baseline always persists — there was no valid snapshot to reuse.
              skip_save = result.no_change?
            else
              # The fact surface moved (a plugin sig/catalog edit), a plugin is opaque, or the effects
              # identity moved: the cached-served files the recheck merged may be stale (or, for effects, a
              # partial collection cannot be closed), so re-analyze the whole tree. The current fact-surface
              # digest (from the recheck runner) is unchanged by the re-analysis, so it is kept for the save.
              # Only a genuine fact-surface reason sets the reporting flag the CLI banner reads.
              @fact_surface_invalidated = true unless fact_reusable
              diagnostics = baseline
              warm = false
              skip_save = false
            end
          else
            diagnostics = baseline
            adopt_plugin_fact_fingerprint
            warm = false
            skip_save = false
          end
          snapshot.save(fingerprint: fingerprint, payload: to_payload) if persist && fingerprint && !skip_save
          [diagnostics, warm]
        end
      end

      # ADR-88 WD1 — reporting hooks the CLI reads after {#run_incremental}. `fact_surface_invalidated?` is true
      # when a valid snapshot was dropped for a fact-surface reason (a plugin sig/catalog edit, or an opaque
      # plugin) rather than a cold miss. `opaque_plugin_ids` names the contributing-but-surfaceless plugins that
      # force a full run every invocation.
      attr_reader :opaque_plugin_ids

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
      def adopt_plugin_fact_fingerprint
        fact = compute_plugin_fact_fingerprint
        @plugin_fact_digest = fact.digest
        @opaque_plugin_ids = fact.opaque_plugin_ids
        @plugin_fact_reusable = fact
      end

      # ADR-88 WD1 — the plugin fact-surface fingerprint for this invocation. For a SEQUENTIAL run it is read
      # post-hoc from the analysis runner's already-prepared registry (no second `#prepare`, producers already
      # validated during analysis). A POOLED run's main process skips `#prepare`, so its registry carries no
      # published facts — there it falls back to the always-sequential probe. Both paths compute the identical
      # digest for a given fact surface, so the reuse decision is worker-count-independent (the parity spec
      # asserts this).
      def compute_plugin_fact_fingerprint
        registry = @last_runner&.plugin_registry
        if @workers.zero? && registry && !registry.empty?
          PluginFactFingerprint.from_registry(registry)
        else
          PluginFactFingerprint.compute(
            configuration: @configuration, cache_store: @cache_store, plugin_requirer: @plugin_requirer
          )
        end
      end

      # Adopt a persisted snapshot's per-file state as this session's baseline (the warm-start path).
      def restore(payload)
        @analyzed = payload.analyzed
        @cache = payload.cache
        @sources = payload.sources
        @digests = payload.digests
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
        # ADR-46 slice 3 — restore negative edges if present (absent in pre-slice-3 snapshots → empty, which
        # only loses the appeared-symbol re-check refinement; such a snapshot is never loaded by a slice-3+
        # engine because the engine version + schema is part of the snapshot fingerprint, and
        # `--verify-incremental` backstops any residual under-capture, so it is never unsound).
        @missing           = payload.missing || {}
        @class_decls       = payload.class_decls || {}
        @return_summaries  = payload.return_summaries || {}
        @param_table       = payload.param_table || {} # ADR-67 WD6c lift — the seeds the cache was built under.
        # ADR-103 WD13 / #382 — the effects sidecar rides its own identity, so a snapshot whose summaries
        # were collected under a different vocabulary / catalogue / `effects:` block restores as EMPTY
        # rather than as stale rows. {#run_incremental} turns that emptiness into a full baseline, because
        # a partial re-collection cannot be closed into a whole-project fixpoint.
        @effects_identity  = payload.effects_identity
        @effect_collections = effect_collections_reusable?(payload) ? payload.effect_collections.dup : {}
        @symbol_dependents = Incremental.invert_symbols(@symbol_sources)
        @ancestry_dependents = Incremental.invert(@ancestry_sources)
        @negative_dependents = Incremental.invert(@missing)
      end

      def to_payload
        Cache::IncrementalSnapshot::Payload.new(
          cache: @cache, sources: @sources, digests: @digests, analyzed: @analyzed,
          symbol_sources: @symbol_sources, ancestry_sources: @ancestry_sources,
          symbol_fingerprints: @symbol_fingerprints, missing: @missing,
          class_decls: @class_decls, seed_bundles: @seed_bundles,
          plugin_fact_digest: @plugin_fact_digest,
          return_summaries: marshal_safe_return_summaries,
          param_table: marshal_safe_param_table,
          effect_collections: marshal_safe_effect_collections,
          effects_identity: @effects_identity
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
      def absorb(runner, fresh, current, analyze_set, removed)
        removed.each { |path| forget(path) }
        @analyzed = current
        # ADR-85 WD2 — the recheck's discovery folded the restored bundles and refreshed them (changed files
        # re-walked, removed files dropped, added files built), so adopt the runner's current set wholesale.
        @seed_bundles = runner.seed_bundles
        fresh_by_file = per_file(fresh)
        analyze_set.each do |path|
          @cache[path] = fresh_by_file[path] || []
          @digests[path] = pack_digest(path)
        end
        absorb_dependency_graph(runner)
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
      # a prior missed lookup. Maps each appeared `"ClassName#method"` to the negative-dependency key it
      # would satisfy (`toplevel:foo` for a top-level def, `method:C#m` otherwise), then unions the recorded
      # negative-dependents of those keys.
      def negative_affected(changed, new_fingerprints, new_class_decls)
        appeared_methods = Incremental.appeared_symbols(changed, @symbol_fingerprints, new_fingerprints)
        appeared_classes = Incremental.appeared_classes(changed, @class_decls, new_class_decls)
        keys = appeared_methods.map { |symbol| negative_key_for(symbol) }
        keys.concat(appeared_classes.map { |klass| "class:#{klass.split('::').last}" })
        Incremental.negative_closure(keys, @negative_dependents)
      end

      # The qualified class/module names declared in the pre-parsed `index` (shared with
      # {#symbol_fingerprints_from_index}, so the changed set is parsed once). `{ path => Set<class name> }`.
      def class_declarations_from_index(index)
        return {} if index.nil?

        result = Hash.new { |hash, key| hash[key] = Set.new }
        index[:class_sources].each do |class_name, files|
          files.each { |file| result[file] << class_name }
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

      # B1 — plugin require-names that ingest COMMENT content as semantic input (inline-RBS reads `# @rbs` /
      # `#:` annotations). B1's code fingerprint ignores comments, so a project configuring one of these opts
      # OUT of the bundle-equality skip (a comment edit could change a cross-file type it contributes).
      COMMENT_INGESTING_PLUGIN_IDS = %w[rigor-rbs-inline].freeze
      private_constant :COMMENT_INGESTING_PLUGIN_IDS

      def negative_key_for(symbol)
        class_name, method = symbol.split("#", 2)
        class_name == TOP_LEVEL_KEY ? "toplevel:#{method}" : "method:#{symbol}"
      end

      def build_runner(**)
        Runner.new(
          configuration: @configuration, cache_store: @cache_store, environment: @environment,
          plugin_requirer: @plugin_requirer, seed_bundles: @seed_bundles, collect_seed_bundles: true,
          workers: @workers, buffer: @buffer, **
        )
      end

      # Run the runner over the session's explicit paths (or, when none were given, the configuration's
      # `paths:` via `Runner#run`'s default).
      def run_runner(runner)
        @paths ? runner.run(@paths) : runner.run
      end

      # Group diagnostics by their file path, keeping only those whose path is an analyzed project file —
      # run-level streams (the gem-RBS info diagnostic, keyed on `.rigor.yml`) are recomputed fresh every
      # run and must not be served from the per-file cache.
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

      # A bound buffer's logical path is never fresh: the bytes to analyse live in the editor's temp file, and
      # the recorded entry describes the file on disk. Re-analysing it when the two happen to agree costs one
      # file; trusting the stat tuple would serve the editor its own stale diagnostics.
      def buffer_path?(path)
        !@buffer.nil? && path == @buffer.logical_path
      end

      # True when `path`'s recorded stat entry proves it unchanged since the last analysis. Any stat / parse
      # failure (missing entry, unreadable / vanished file) reads as NOT fresh (→ re-analyse), preserving the
      # prior `digest(path) != recorded` "changed" semantics for a file that cannot be validated.
      def stat_fresh?(path)
        return false if buffer_path?(path)

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
