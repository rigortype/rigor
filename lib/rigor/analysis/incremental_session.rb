# frozen_string_literal: true

require "digest"
require_relative "incremental"
require_relative "../cache/incremental_snapshot"
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
      def initialize(configuration:, paths: nil, environment: nil, cache_store: nil, plugin_requirer: nil)
        @configuration = configuration
        @paths = paths
        @environment = environment
        @cache_store = cache_store
        @plugin_requirer = plugin_requirer
        # ADR-85 WD2 — per-file discovery seed bundles keyed by logical path. A cold baseline builds them; a
        # warm recheck folds them (re-walking only changed files) and refreshes the set. Ride the snapshot.
        @seed_bundles = {}
        @cache = {}              # analyzed path => [Diagnostic]
        @sources = {}            # analyzed path => Set<source path it read from>
        @digests = {}            # analyzed path => content digest at last analysis
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
      end

      # The project files analyzed at the last baseline / recheck — the set a verify pass partitions and the
      # merge subtracts the affected closure from.
      def analyzed_files
        @analyzed
      end

      # Full baseline analysis with recording. Returns the run's diagnostics; populates the in-process cache
      # + dependency state.
      def baseline
        runner = build_runner(record_dependencies: true)
        diagnostics = run_runner(runner).diagnostics
        @analyzed = runner.analyzed_files
        @seed_bundles = runner.seed_bundles # ADR-85 WD2 — the freshly built bundle set for the next run.
        absorb_dependency_graph(runner)
        @cache = per_file(diagnostics)
        @digests = @analyzed.to_h { |path| [path, digest(path)] }
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
        changed = (current & previous).reject { |path| digest(path) == @digests[path] }
        affected = affected_closure(changed, added, removed)
        analyze_set = affected & current
        runner = build_runner(analyze_only: analyze_set, record_dependencies: true)
        fresh = run_runner(runner).diagnostics
        reused = (current & previous) - affected.to_a
        merged = fresh + reused.flat_map { |path| @cache[path] || [] }
        absorb(runner, fresh, current, analyze_set, removed)
        Recheck.new(diagnostics: merged, changed: changed.to_set, added: added.to_set,
                    removed: removed.to_set, affected: affected, reused: reused.to_set)
      end

      # The frozen set of files a #recheck must re-analyse: the symbol/ancestry-granularity closure of the
      # changed files (slice 4), the added files themselves, the consumers of any symbol / class that
      # *appeared* in a changed OR added file (slice 3 — a now-defined `call.unresolved-toplevel` target or
      # `def.override-*` ancestor), and the consumers of every removed file (which now miss what it
      # provided). An added file has no before-state, so all its symbols / classes appear.
      def affected_closure(changed, added, removed)
        scan = changed + added
        new_fps = symbol_fingerprints_for(scan)
        new_class_decls = class_declarations_for(scan)
        changed_pairs = Incremental.changed_symbol_pairs(changed, @symbol_fingerprints, new_fps)
        base = if changed_pairs.any? || changed.any? { |f| @ancestry_dependents[f] }
                 Incremental.affected_with_symbols(changed, changed_pairs, @symbol_dependents, @ancestry_dependents)
               else
                 Incremental.affected(changed, @dependents)
               end
        closure = base | added.to_set | negative_affected(scan, new_fps, new_class_decls)
        removed.each { |path| closure |= @dependents[path] || Set.new }
        closure.freeze
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
        runner = build_runner(analyze_only: affected)
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
      def run_incremental(snapshot:, fingerprint:)
        restored = fingerprint && snapshot.load(fingerprint: fingerprint)
        if restored
          restore(restored)
          result = recheck
          diagnostics = result.diagnostics
          warm = true
          # ADR-87 WD3 — a warm recheck that changed nothing leaves the session state byte-equivalent to the
          # snapshot it restored, so skip the unconditional rewrite (209ms + 2 MB on gitlab per null recheck).
          # A cold baseline always persists — there was no valid snapshot to reuse.
          skip_save = result.no_change?
        else
          diagnostics = baseline
          warm = false
          skip_save = false
        end
        snapshot.save(fingerprint: fingerprint, payload: to_payload) if fingerprint && !skip_save
        [diagnostics, warm]
      end

      private

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
        @symbol_dependents = Incremental.invert_symbols(@symbol_sources)
        @ancestry_dependents = Incremental.invert(@ancestry_sources)
        @negative_dependents = Incremental.invert(@missing)
      end

      def to_payload
        Cache::IncrementalSnapshot::Payload.new(
          cache: @cache, sources: @sources, digests: @digests, analyzed: @analyzed,
          symbol_sources: @symbol_sources, ancestry_sources: @ancestry_sources,
          symbol_fingerprints: @symbol_fingerprints, missing: @missing,
          class_decls: @class_decls, seed_bundles: @seed_bundles
        )
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
          @digests[path] = digest(path)
        end
        absorb_dependency_graph(runner)
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

      # Compute per-symbol body fingerprints for `paths` via a quick indexing re-pass (Prism parse + def
      # extraction, no type inference). Returns a hash of the form `{ path => { "ClassName#method" =>
      # sha256_hex } }`. Used by {#recheck} to detect which symbols in a changed file actually changed, so
      # only their callers are added to the affected closure.
      def symbol_fingerprints_for(paths)
        return {} if paths.empty?

        index = Inference::ScopeIndexer.discovered_def_index_for_paths(paths)
        def_nodes   = index[:def_nodes]
        def_sources = index[:def_sources]
        result = Hash.new { |h, k| h[k] = {} }
        def_sources.each do |class_name, methods|
          methods.each do |method_sym, path_line|
            path = path_line.split(":", 2).first
            node = def_nodes.dig(class_name, method_sym)
            next unless node

            result[path]["#{class_name}##{method_sym}"] =
              Digest::SHA256.hexdigest(node.location.slice)
          end
        end
        result.transform_values(&:freeze).freeze
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

      # The qualified class/module names declared in `paths`, via the same quick indexing re-pass
      # {#symbol_fingerprints_for} uses (Prism parse + declaration extraction, no inference). `{ path =>
      # Set<class name> }`.
      def class_declarations_for(paths)
        return {} if paths.empty?

        index = Inference::ScopeIndexer.discovered_def_index_for_paths(paths)
        result = Hash.new { |hash, key| hash[key] = Set.new }
        index[:class_sources].each do |class_name, files|
          files.each { |file| result[file] << class_name }
        end
        result.transform_values(&:freeze).freeze
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
          plugin_requirer: @plugin_requirer, seed_bundles: @seed_bundles, collect_seed_bundles: true, **
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

      def digest(path)
        Digest::SHA256.hexdigest(File.read(path))
      rescue StandardError
        "missing"
      end
    end
  end
end
