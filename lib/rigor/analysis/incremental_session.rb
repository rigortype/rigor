# frozen_string_literal: true

require "digest"
require_relative "incremental"
require_relative "../cache/incremental_snapshot"
require_relative "../inference/scope_indexer"

module Rigor
  module Analysis
    # ADR-46 slice 2 — the in-memory incremental orchestrator that composes
    # the recorded dependency graph ({Runner#file_dependents}), the affected
    # closure ({Incremental.affected}), and the subset-analysis hook
    # ({Runner} `analyze_only:`) into a working incremental re-check.
    #
    # `#baseline` runs a full analysis with dependency recording and keeps,
    # per analyzed file, its diagnostics (the cache), its content digest,
    # and the per-file source set (to maintain the dependents index across
    # rounds). `#recheck` digests the files again, computes the changed set
    # ΔF, re-analyzes only `ΔF ∪ dependents[ΔF]`, and serves every other
    # analyzed file from the cache — the body tier.
    #
    # The invariant the verify harness (and the spec) assert: `#recheck`'s
    # merged diagnostics are byte-identical (as a sorted set) to a full
    # `--no-cache` re-analysis of the edited tree. This is the
    # `--verify-incremental` acceptance gate, here without disk persistence
    # or CLI wiring (the cache is in-process). It models the body tier only:
    # an edit that adds / removes / moves a *file* is outside the analyzed
    # set it maintains and falls to a fresh {#baseline} (the structural tier
    # is a later slice).
    class IncrementalSession
      # The outcome of a {#recheck}: the merged diagnostics plus the file
      # sets, so a caller (or the verify gate) can report what was
      # re-analyzed versus served from cache.
      Recheck = Data.define(:diagnostics, :changed, :affected, :reused)

      # @param paths [Array<String>, nil] explicit analysis roots; nil
      #   (the default) uses the configuration's `paths:`.
      def initialize(configuration:, paths: nil)
        @configuration = configuration
        @paths = paths
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
      end

      # The project files analyzed at the last baseline / recheck — the set
      # a verify pass partitions and the merge subtracts the affected
      # closure from.
      def analyzed_files
        @analyzed
      end

      # Full baseline analysis with recording. Returns the run's
      # diagnostics; populates the in-process cache + dependency state.
      def baseline
        runner = build_runner(record_dependencies: true)
        diagnostics = run_runner(runner).diagnostics
        @analyzed = runner.analyzed_files
        absorb_dependency_graph(runner)
        @cache = per_file(diagnostics)
        @digests = @analyzed.to_h { |path| [path, digest(path)] }
        diagnostics
      end

      # Re-check after on-disk edits. Re-analyzes only the affected closure
      # and serves the rest from cache; refreshes the cache + dependency
      # state so a subsequent #recheck sees the new world.
      def recheck
        changed = @analyzed.reject { |path| digest(path) == @digests[path] }
        # ADR-46 slice 4 — compute symbol fingerprints for the changed files
        # via a quick indexing re-pass, then use symbol-granularity affected
        # computation so that callers of unchanged symbols are spared.
        new_fps = symbol_fingerprints_for(changed)
        changed_pairs = Incremental.changed_symbol_pairs(changed, @symbol_fingerprints, new_fps)
        affected = if changed_pairs.any? || changed.any? { |f| @ancestry_dependents[f] }
                     Incremental.affected_with_symbols(
                       changed, changed_pairs, @symbol_dependents, @ancestry_dependents
                     )
                   else
                     Incremental.affected(changed, @dependents)
                   end
        # ADR-46 slice 3 — widen for symbols that *appeared* in the changed
        # files and resolve a prior negative (missing) lookup, so a consumer
        # whose `call.unresolved-toplevel` (or analogous miss) is now defined
        # gets re-checked rather than served a stale diagnostic.
        affected = (affected | negative_affected(changed, new_fps)).freeze
        runner = build_runner(analyze_only: affected, record_dependencies: true)
        fresh = run_runner(runner).diagnostics
        reused = @analyzed - affected.to_a
        merged = fresh + reused.flat_map { |path| @cache[path] || [] }
        absorb(runner, fresh, affected, changed)
        Recheck.new(diagnostics: merged, changed: changed.to_set, affected: affected, reused: reused.to_set)
      end

      # Verification engine (the `--verify-incremental` gate): with NO
      # source edit, re-analyze `subset` fresh and serve every other
      # analyzed file from the baseline cache. Because nothing on disk
      # changed, the merged result MUST equal a full analysis — so this
      # exercises the subset-analysis and cache-merge paths against a
      # known-good oracle (a full `--no-cache` run) for an arbitrary
      # partition, without mutating session state. Returns the merged
      # diagnostics.
      def reanalyze_subset(subset)
        affected = subset.to_set
        runner = build_runner(analyze_only: affected)
        fresh = run_runner(runner).diagnostics
        reused = @analyzed - affected.to_a
        fresh + reused.flat_map { |path| @cache[path] || [] }
      end

      # Cross-process incremental run (the `--incremental` flag's engine).
      # With a disk `snapshot` whose `fingerprint` matches, restore the
      # prior per-file state and `#recheck` (re-analyze only the changed
      # closure, serve the rest from the restored cache); otherwise run a
      # full `#baseline`. Either way, persist the updated snapshot for the
      # next process. Returns `[diagnostics, warm]` — `warm` is true when a
      # snapshot was restored. A nil `fingerprint` (uncomputable inputs)
      # disables persistence: a plain full run.
      def run_incremental(snapshot:, fingerprint:)
        restored = fingerprint && snapshot.load(fingerprint: fingerprint)
        if restored
          restore(restored)
          diagnostics = recheck.diagnostics
          warm = true
        else
          diagnostics = baseline
          warm = false
        end
        snapshot.save(fingerprint: fingerprint, payload: to_payload) if fingerprint
        [diagnostics, warm]
      end

      private

      # Adopt a persisted snapshot's per-file state as this session's
      # baseline (the warm-start path).
      def restore(payload)
        @analyzed = payload.analyzed
        @cache = payload.cache
        @sources = payload.sources
        @digests = payload.digests
        @dependents = Incremental.invert(@sources)
        # ADR-46 slice 4 — restore symbol-granularity state if present in the
        # payload (absent in snapshots written before slice 4 → fall back to
        # file-level dependents, which is always sound).
        @symbol_sources    = payload.symbol_sources    || {}
        @ancestry_sources  = payload.ancestry_sources  || {}
        @symbol_fingerprints = payload.symbol_fingerprints || {}
        # ADR-46 slice 3 — restore negative edges if present (absent in
        # pre-slice-3 snapshots → empty, which only loses the appeared-symbol
        # re-check refinement; the fingerprint still drops the snapshot on a
        # file add/remove, so it is never unsound).
        @missing           = payload.missing || {}
        @symbol_dependents = Incremental.invert_symbols(@symbol_sources)
        @ancestry_dependents = Incremental.invert(@ancestry_sources)
        @negative_dependents = Incremental.invert(@missing)
      end

      def to_payload
        Cache::IncrementalSnapshot::Payload.new(
          cache: @cache, sources: @sources, digests: @digests, analyzed: @analyzed,
          symbol_sources: @symbol_sources, ancestry_sources: @ancestry_sources,
          symbol_fingerprints: @symbol_fingerprints, missing: @missing
        )
      end

      # Fold a #recheck's fresh results back into the cache + graph so the
      # session is correct across multiple edits: the re-analyzed files get
      # fresh diagnostics, sources, and digests; every other file's state is
      # carried over untouched.
      def absorb(runner, fresh, affected, changed)
        fresh_by_file = per_file(fresh)
        affected.each { |path| @cache[path] = fresh_by_file[path] || [] }
        absorb_dependency_graph(runner)
        changed.each { |path| @digests[path] = digest(path) }
      end

      # Fold a runner's dependency recording (file-level and symbol-level) back
      # into the session's graph state. Rebuilds all derived indexes.
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
      end

      # Compute per-symbol body fingerprints for `paths` via a quick indexing
      # re-pass (Prism parse + def extraction, no type inference). Returns a
      # hash of the form `{ path => { "ClassName#method" => sha256_hex } }`.
      # Used by {#recheck} to detect which symbols in a changed file actually
      # changed, so only their callers are added to the affected closure.
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

      # ADR-46 slice 3 — the consumers to re-check because a symbol that
      # appeared in a changed file resolves a prior missed lookup. Maps each
      # appeared `"ClassName#method"` to the negative-dependency key it would
      # satisfy (`toplevel:foo` for a top-level def, `method:C#m` otherwise),
      # then unions the recorded negative-dependents of those keys.
      def negative_affected(changed, new_fingerprints)
        appeared = Incremental.appeared_symbols(changed, @symbol_fingerprints, new_fingerprints)
        keys = appeared.map { |symbol| negative_key_for(symbol) }
        Incremental.negative_closure(keys, @negative_dependents)
      end

      TOP_LEVEL_KEY = Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY
      private_constant :TOP_LEVEL_KEY

      def negative_key_for(symbol)
        class_name, method = symbol.split("#", 2)
        class_name == TOP_LEVEL_KEY ? "toplevel:#{method}" : "method:#{symbol}"
      end

      def build_runner(**)
        Runner.new(configuration: @configuration, cache_store: nil, **)
      end

      # Run the runner over the session's explicit paths (or, when none were
      # given, the configuration's `paths:` via `Runner#run`'s default).
      def run_runner(runner)
        @paths ? runner.run(@paths) : runner.run
      end

      # Group diagnostics by their file path, keeping only those whose path
      # is an analyzed project file — run-level streams (the gem-RBS info
      # diagnostic, keyed on `.rigor.yml`) are recomputed fresh every run
      # and must not be served from the per-file cache.
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
