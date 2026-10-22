# frozen_string_literal: true

require_relative "../inference/parameter_inference_collector"
require_relative "../inference/scope_indexer"
require_relative "../inference/project_seed_tables"
require_relative "../cache/incremental_snapshot"
require_relative "../analysis/path_expansion"
require_relative "../analysis/buffer_binding"

module Rigor
  module Protection
    # Issue #260 — the cross-file knowledge Tier 2 hands to BOTH halves of a mutation measurement.
    #
    # Site selection and the kill oracle used to disagree by construction: the site filter judged a receiver
    # against a scope seeded with `discovered_classes`, so `Account.find` (with `Account` declared in a sibling
    # file) entered the denominator — while the oracle re-analysed each mutant through
    # `Runner.new(prebuilt:)#run_source`, whose cross-file discovery tables stay frozen-empty, so the same
    # receiver read `Dynamic` and NO mutation at that site could ever produce a diagnostic. Every admitted
    # cross-file site was therefore a guaranteed survivor: on Rigor's own `lib`, +2,183 sites bought +2,187
    # survivors and moved `killed` by −4.
    #
    # The answer (issue #260's recorded decision) is one table set, built once, threaded to both sides: the
    # {Mutator} base scope and {DiagnosticOracle}'s runner seam. This module builds that table set — the FULL
    # discovery bundle (`discovered_def_nodes`, `discovered_methods`, superclasses, includes, extends, …), not just
    # the class-identity slice site selection needed, because resolving `find` on `singleton(Account)` is what makes
    # the site killable.
    #
    # The shape is a plain Hash of {Scope::DiscoveryIndex} slot names, which is exactly what both consumers take:
    # `scope.discovery.with(**tables)` on one side, `Runner#project_scope_seed_tables` on the other.
    #
    # Built ONCE on the parent, before {CLI::MutationForkScan} forks, so children copy-on-write inherit it.
    # Nothing here crosses the marshal boundary (only per-file results do) — which matters, because the def-node
    # tables hold live `Prism::Node`s.
    module DiscoverySeed
      module_function

      # @param paths — the measured file set; the seed spans these files only, exactly as Tier 1's
      #   seed does. A class declared outside them stays unknown.
      # @param environment — the plugin-aware environment, built once by the caller.
      # @param target_ruby — Prism parse version for the parameter-inference pre-pass.
      # @param workers — worker count for that pre-pass (0 keeps it sequential).
      # @return frozen seed tables; empty when the paths yield nothing.
      def build(paths:, environment:, target_ruby:, workers: 0)
        tables = discovery_tables(paths)
        params = Inference::ParameterInferenceCollector.collect(
          files: paths, environment: environment, target_ruby: target_ruby, workers: workers
        )
        tables[:param_inferred_types] = params unless params.empty?
        tables.freeze
      end

      # Issue #254 — the per-file discovery *bundles* (ADR-85 WD2) the closure kill oracle re-folds once per
      # mutant. A bundle is one file's isolated contribution to the tables above, plus the content digest that
      # decides whether it is still valid; folding the whole set reconstructs exactly what {#discovery_tables}
      # builds. Built ONCE on the parent (before {CLI::MutationForkScan} forks, so children copy-on-write
      # inherit it), and cheap: ≈0.36s over Rigor's own 349-file `lib`.
      #
      # @param paths — the measured file set, in canonical (caller) order.
      # @return per-path bundles, the input {#tables_for_buffer} re-folds.
      def bundles(paths:)
        Inference::ScopeIndexer.discovered_project_index_incremental(paths, seed_bundles: {}).fetch(:bundles)
      end

      # Issue #254 — the seed tables for ONE mutant: every measured file's bundle folded back unchanged
      # EXCEPT the file `buffer` binds, which is re-walked from the buffer's bytes.
      #
      # This is where the substitution reaches change detection rather than only the analysis. The
      # incremental pass digests each path through the binding, so the mutated file's digest is the MUTANT's
      # and never matches its cached bundle — it is re-walked, and every dependent then reads the mutated
      # `def` bodies out of the seed instead of the ones still on disk. Without it a closure re-analysis
      # would resolve the clean method, produce no new diagnostic anywhere but the mutated file itself, and
      # report a plausible-looking effectiveness number that measured nothing new.
      #
      # ≈15ms over 349 files (one re-walk plus a whole-set fold), against ≈210ms for one mutant's analysis.
      #
      # @param paths — the measured file set, in the same order {#bundles} was built from.
      # @param bundles — that bundle set.
      # @param buffer — the mutant binding (logical path → mutant bytes).
      # @param constant_sources — ADR-124 — also carry the per-name writer paths (`constant_sources`), which a
      #   `prebuilt:` runner needs to retract a `pre_eval:` constant another file also assigns (#663).
      # @return frozen seed tables.
      def tables_for_buffer(paths:, bundles:, buffer:, constant_sources: false)
        index = Inference::ScopeIndexer.discovered_project_index_incremental(
          paths, seed_bundles: bundles, buffer: buffer
        )
        tables = seed_tables(index)
        sources = index.fetch(:def_index).fetch(:constant_sources)
        tables = tables.merge(constant_sources: sources) if constant_sources && !sources.empty?
        tables.freeze
      end

      # Issue #512 — the seed a one-shot probe (`rigor type-of`) can afford: the cross-file discovery tables for
      # the configured paths, folded from the per-file bundles a prior `rigor check --incremental` left in the
      # persistent snapshot, with `buffer`'s file (and any file whose bytes moved since) re-walked. A probe has
      # no business re-parsing the project — that is what made the first attempt cost twice a single-file probe —
      # so when there is no reusable snapshot this answers nil and the caller keeps its single-file scope. It
      # never writes the snapshot.
      #
      # The snapshot is reused only under the fingerprint a bare `rigor check --incremental` writes (roots = the
      # configured paths, the plain run mode): any other fingerprint, a different engine, configuration,
      # lockfile or `sig/` included, is a miss.
      #
      # @param configuration — the probe's loaded configuration.
      # @param buffer — the editor binding, or nil.
      # @return frozen seed tables, or nil when the snapshot cannot seed this project.
      def from_snapshot(configuration:, buffer: nil)
        paths = Analysis::PathExpansion.configured_files(configuration)
        return nil if paths.empty?

        bundles = snapshot_bundles(configuration)
        return nil if bundles.nil? || bundles.empty?

        tables_for_buffer(paths: respell_for_buffer(paths, buffer), bundles: bundles, buffer: buffer,
                          constant_sources: true)
      end

      # The configured file list with the entry that reaches `buffer`'s file respelled as the buffer's logical
      # path: the binding substitutes bytes only for a path spelled exactly as its logical path, while the
      # configured paths may be relative or reach the file through a symlink. `real_paths` is the memoised
      # `BufferBinding.real_path` of each entry when the caller keeps one.
      def respell_for_buffer(paths, buffer, real_paths: nil)
        return paths if buffer.nil?

        real = Analysis::BufferBinding.real_path(buffer.logical_path)
        paths.each_with_index.map do |path, index|
          entry_real = real_paths ? real_paths[index] : Analysis::BufferBinding.real_path(path)
          entry_real == real ? buffer.logical_path : path
        end
      end

      def snapshot_bundles(configuration)
        fingerprint = Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: configuration.paths)
        return nil if fingerprint.nil?

        loaded = Cache::IncrementalSnapshot.new(root: configuration.cache_path).load_any(fingerprints: [fingerprint])
        loaded&.last&.seed_bundles
      end

      # The whole-project discovery tables, from the single-walk combined pass (one parse per file) that
      # {Analysis::Runner::ProjectPrePasses#discover} uses, mapped by the one list {Inference::ProjectSeedTables}
      # keeps (issue #1614). Empty tables are dropped so an empty seed stays `{}` and every consumer's "seed nothing"
      # branch keeps working.
      def discovery_tables(paths)
        seed_tables(Inference::ScopeIndexer.discovered_project_index_for_paths(paths))
      end

      # Maps a `{ classes:, def_index: }` discovery index onto the {Scope::DiscoveryIndex} slot names both consumers
      # take. Shared by the whole-walk ({#discovery_tables}) and bundle-fold ({#tables_for_buffer}) producers so a
      # mutant's seed and the parent's seed can never disagree about shape.
      def seed_tables(index)
        Inference::ProjectSeedTables.from_index(index)
      end
    end
  end
end
