# frozen_string_literal: true

require_relative "scope_indexer"

module Rigor
  module Inference
    # Issue #1614 — the cross-file discovery seed the paths that type a project WITHOUT a `check` run hand their
    # per-file scopes: {Protection::DiscoverySeed} (the protection scan, `rigor coverage`) and
    # {ParameterInferenceCollector} (the ADR-67 call-site pre-pass, which `check` itself runs under
    # `parameter_inference:`). Each used to keep its own list of tables, and each dropped some that
    # `Analysis::Runner#project_scope_seed_tables` carries, so a cross-file constant read `30` under `check` and
    # `Dynamic` under coverage, and a parameter whose call sites pass it went uninferred.
    #
    # This module is the one list both paths read. {Analysis::Runner#project_scope_seed_tables} stays the
    # reference; `spec/rigor/inference/project_seed_tables_spec.rb` compares the two over a project that fills
    # every table, and requires each table the runner seeds and this one does not to be in {NOT_SEEDED}, with its
    # reason.
    module ProjectSeedTables
      module_function

      # The def-index slots that seed a per-file scope as they are, each with the {Scope::DiscoveryIndex} member it
      # fills.
      SLOTS = {
        def_nodes: :discovered_def_nodes, def_nestings: :discovered_def_nestings,
        singleton_def_nodes: :discovered_singleton_def_nodes, def_sources: :discovered_def_sources,
        singleton_def_sources: :discovered_singleton_def_sources, superclasses: :discovered_superclasses,
        header_nestings: :discovered_header_nestings, includes: :discovered_includes,
        prepends: :discovered_prepends, extends: :discovered_extends, unpositioned_mixins: :unpositioned_mixins,
        class_sources: :discovered_class_sources, method_visibilities: :discovered_method_visibilities,
        methods: :discovered_methods, parameter_envelopes: :discovered_parameter_envelopes,
        data_member_layouts: :data_member_layouts, struct_member_layouts: :struct_member_layouts,
        deferred_ranges: :discovered_deferred_ranges, refinements: :discovered_refinements,
        global_write_census: :discovered_global_write_census
      }.freeze

      # The tables `Runner#project_scope_seed_tables` can seed that {.from_index} leaves out, and why.
      NOT_SEEDED = {
        run_generation: "the identity token of a check run's return memo; these paths run no check",
        constant_sources: "read only by dependency recording, which only an incremental check run turns on",
        param_inferred_types: "the parameter-inference output itself; each caller adds its own " \
                              "(DiscoverySeed.build, coverage under parameter_inference:, the collector's last round)"
      }.freeze

      # The seed tables over `paths`, from one parse of each file.
      def for_paths(paths)
        from_index(ScopeIndexer.discovered_project_index_for_paths(paths))
      end

      # Maps a `{ classes:, def_index: }` discovery index onto {Scope::DiscoveryIndex} member names. Empty tables are
      # dropped so an empty seed stays `{}`; a paired member and its sibling are dropped only together.
      #
      # `in_source_constants` is the project's literal constant table alone: the `pre_eval:` publication a `check` run
      # joins to it types each listed file's writes against the RBS environment, which these paths do not build first.
      def from_index(index)
        def_index = index.fetch(:def_index)
        tables = { discovered_classes: index.fetch(:classes) }
        SLOTS.each { |slot, member| tables[member] = def_index.fetch(slot) }
        tables.merge!(constant_tables(def_index.fetch(:constant_values), def_index.fetch(:constant_writes)))
        tables.merge!(def_index.fetch(:siblings))
        Scope::DiscoveryIndex.compact_pairs(
          tables.reject { |name, table| !Scope::DiscoveryIndex.paired?(name) && (table.nil? || table.empty?) }
        )
      end

      def constant_tables(values, writes)
        {
          in_source_constants: values,
          published_constant_names: published_constant_names(values),
          constant_writers: constant_writers(writes),
          constant_shadowers: constant_shadowers(writes)
        }
      end

      # Issue #644 — the last segments of the published constant table, the run-wide half of
      # `Scope#published_constant?`.
      def published_constant_names(values)
        values.keys.to_set { |name| name.split("::").last }.freeze
      end

      # Issue #617 — the censused names that bind, grouped by last segment (`Scope#bound_constant_names`). A name some
      # write other than a memo `||=` touches always binds. A memo-only name binds once memos of its segment span two
      # files: either may load first and set the constant the other then reads, so only a memo no other file shares
      # keeps the idiom's reading. Files are counted expanded, because discovery can walk one file under two
      # spellings (`lib/b.rb`, `./lib/b.rb`).
      def constant_writers(writes)
        memo_files = memo_files_by_segment(writes)
        writes.each_with_object({}) do |(name, by_path), index|
          segment = name.split("::").last
          next if memo_only?(by_path) && memo_files.fetch(segment).size < 2

          (index[segment] ||= []) << name
        end.each_value(&:freeze).freeze
      end

      # Issue #1290 — the censused names some write other than a memo `||=` assigns, grouped by last segment
      # (`Scope#shadowing_constant_names`): the ones that exist whether or not an outer constant of the name does, and
      # so stop the lexical ladder above it. A memo-only name is left out however many files memoize it, unlike in
      # {.constant_writers}: `X ||= v` resolves `X` through the very lookup whose lower rung the stop would replace,
      # so wherever that rung answers, the memo finds it and never creates the name.
      def constant_shadowers(writes)
        writes.each_with_object({}) do |(name, by_path), index|
          (index[name.split("::").last] ||= []) << name unless memo_only?(by_path)
        end.each_value(&:freeze).freeze
      end

      def memo_files_by_segment(writes)
        writes.each_with_object({}) do |(name, by_path), files|
          set = (files[name.split("::").last] ||= Set.new)
          by_path.each { |path, descriptor| set << File.absolute_path(path) if memo_descriptor?(descriptor) }
        end
      end

      def memo_only?(by_path) = by_path.each_value.all? { |descriptor| memo_descriptor?(descriptor) }
      def memo_descriptor?(descriptor) = descriptor == ScopeIndexer::CONSTANT_MEMO
    end
  end
end
