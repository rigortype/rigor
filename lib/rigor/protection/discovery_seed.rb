# frozen_string_literal: true

require_relative "../inference/parameter_inference_collector"
require_relative "../inference/scope_indexer"

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
    # discovery bundle (`discovered_def_nodes`, `discovered_methods`, superclasses, includes, …), not just the
    # class-identity slice site selection needed, because resolving `find` on `singleton(Account)` is what makes
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

      # @param paths [Array<String>] the measured file set; the seed spans these files only, exactly as Tier 1's
      #   seed does. A class declared outside them stays unknown.
      # @param environment [Rigor::Environment] the plugin-aware environment, built once by the caller.
      # @param target_ruby [String] Prism parse version for the parameter-inference pre-pass.
      # @param workers [Integer] worker count for that pre-pass (0 keeps it sequential).
      # @return [Hash{Symbol => Object}] frozen seed tables; empty when the paths yield nothing.
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
      # @param paths [Array<String>] the measured file set, in canonical (caller) order.
      # @return [Hash{String => Hash}] per-path bundles, the input {#tables_for_buffer} re-folds.
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
      # @param paths [Array<String>] the measured file set, in the same order {#bundles} was built from.
      # @param bundles [Hash{String => Hash}] that bundle set.
      # @param buffer [Rigor::Analysis::BufferBinding] the mutant binding (logical path → mutant bytes).
      # @return [Hash{Symbol => Object}] frozen seed tables.
      def tables_for_buffer(paths:, bundles:, buffer:)
        index = Inference::ScopeIndexer.discovered_project_index_incremental(
          paths, seed_bundles: bundles, buffer: buffer
        )
        seed_tables(index).freeze
      end

      # The whole-project discovery tables, from the single-walk combined pass (one parse per file, both
      # collectors driven over the same tree) that {Analysis::Runner::ProjectPrePasses#discover} uses. Empty
      # tables are dropped so an empty seed stays `{}` and every consumer's "seed nothing" branch keeps working.
      #
      # `discovered_class_sources` is deliberately NOT carried: the runner itself seeds it only under dependency
      # recording (it is read by the ancestry accessors solely to record cross-file edges), and Tier 2 never
      # records.
      def discovery_tables(paths)
        seed_tables(Inference::ScopeIndexer.discovered_project_index_for_paths(paths))
      end

      # Maps a `{ classes:, def_index: }` discovery index onto the {Scope::DiscoveryIndex} slot names both
      # consumers take. Shared by the whole-walk ({#discovery_tables}) and bundle-fold ({#tables_for_buffer})
      # producers so a mutant's seed and the parent's seed can never disagree about shape.
      def seed_tables(index)
        def_index = index.fetch(:def_index)
        tables = { discovered_classes: index.fetch(:classes) }
        %i[
          def_nodes singleton_def_nodes def_sources singleton_def_sources superclasses includes
          method_visibilities methods data_member_layouts struct_member_layouts
        ].each do |slot|
          tables[seed_key(slot)] = def_index.fetch(slot)
        end
        tables.reject { |_, table| table.nil? || table.empty? }
      end

      # The def-index slot names match the {Scope::DiscoveryIndex} ones under a `discovered_` prefix, except the
      # two member-layout tables, which carry the same name on both sides.
      def seed_key(slot)
        slot.to_s.end_with?("member_layouts") ? slot : :"discovered_#{slot}"
      end
    end
  end
end
