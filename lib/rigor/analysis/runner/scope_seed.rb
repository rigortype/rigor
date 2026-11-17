# frozen_string_literal: true

require_relative "../../inference/scope_indexer"

module Rigor
  module Analysis
    class Runner
      # The pure parts of {Runner#project_scope_seed_tables}: each fills the `tables` Hash it is handed from the
      # project tables passed beside it (a `Runner` ivar is a parameter of the same name), and reads and writes
      # no `Runner` state. {Runner} keeps the assembly — the order the tables are applied in, the tables whose
      # reads go through a memo (`seed_refinements`, the constant name indexes) or through
      # `PAIRED_MEMBER_IVARS`' ivar names — and calls these once per file's seed.
      module ScopeSeed
        module_function

        # The three mixin tables: the ADR-24 instance-side `include` map, its issue #1123 `prepend` twin
        # (which carries the instance-ancestor order the include table's set-shaped value cannot), and the
        # #898 singleton-side `extend` table. Grouped here because they are read as one picture of a class's
        # ancestry, and split out of {Runner#project_scope_seed_tables} to keep it under the complexity budget.
        def seed_mixin_tables(tables, project_discovered_includes, project_discovered_prepends,
                              project_discovered_extends, project_unpositioned_mixins)
          tables[:discovered_includes] = project_discovered_includes unless project_discovered_includes.empty?
          tables[:discovered_prepends] = project_discovered_prepends unless project_discovered_prepends.empty?
          tables[:discovered_extends] = project_discovered_extends unless project_discovered_extends.empty?
          tables[:unpositioned_mixins] = project_unpositioned_mixins unless project_unpositioned_mixins.empty?
        end

        # ADR-46 slice 1 / issue #644 — the two SOURCE-ATTRIBUTION tables, read by the recording accessors
        # (`Scope#record_class_dependency` for the class-declaration map, `Scope#record_constant_dependency`
        # for the constant-write map). The class-declaration map rides every run: an ancestor-order reader also
        # asks whether a class is declared in more than one file. The constant-write map rides only a recording
        # run. Extracted to keep {Runner#project_scope_seed_tables} under the complexity budget.
        #
        # Issue #617 — the census's binding writes, grouped by last segment, ride every run instead: a constant
        # compound write whose plain read resolves nothing reads its binding off them, a TYPE rather than an edge.
        # Issue #1290's shadowing writes ride beside them for the lexical ladder, for the same reason.
        def seed_dependency_attribution_tables(tables, writers, shadowers, project_discovered_class_sources,
                                               record_dependencies, project_constant_sources)
          tables[:constant_writers] = writers unless writers.empty?
          tables[:constant_shadowers] = shadowers unless shadowers.empty?
          tables[:discovered_class_sources] = project_discovered_class_sources unless
            project_discovered_class_sources.empty?
          return unless record_dependencies

          tables[:constant_sources] = project_constant_sources unless project_constant_sources.empty?
        end

        # ADR-46 — seed the instance + singleton `"path:line"` def-source tables (each only when non-empty).
        # Extracted to keep {Runner#project_scope_seed_tables} under the complexity budget. The singleton table (slice 4
        # extension) rides the same seed so a pooled `WorkerSession` records singleton symbol edges identically.
        def seed_def_source_tables(tables, project_discovered_def_sources, project_discovered_singleton_def_sources)
          tables[:discovered_def_sources] = project_discovered_def_sources unless project_discovered_def_sources.empty?
          return if project_discovered_singleton_def_sources.empty?

          tables[:discovered_singleton_def_sources] = project_discovered_singleton_def_sources
        end

        # ADR-48 — seed the Data + Struct member-layout tables (each only when non-empty). Extracted to keep
        # {Runner#project_scope_seed_tables} under the complexity budget.
        def seed_member_layout_tables(tables, project_data_member_layouts, project_struct_member_layouts)
          tables[:data_member_layouts] = project_data_member_layouts unless project_data_member_layouts.empty?
          return if project_struct_member_layouts.empty?

          tables[:struct_member_layouts] = project_struct_member_layouts
        end

        # Issue #644 — the seeded `in_source_constants` table, joining the two cross-file constant producers.
        # The whole-project literal table wins over a `pre_eval:` publication of the same name: both describe
        # the same assignment, the literal table pins the value the write actually carries while ADR-17's
        # widener erases it to the class, and listing a file under `pre_eval:` must never LOSE precision. The
        # per-file table still wins over both (`ScopeIndexer.index`'s merge) — same-file stays the most
        # specific authority.
        #
        # ADR-124 — a `prebuilt:` runner computes no literal table of its own; a `discovery_seed:` (the editor
        # publish, ADR-124) brings the project's, which then plays the same part.
        def merged_seed_constants(project_pre_eval_constants, project_constant_values, discovery_seed,
                                  project_constant_sources, pre_eval_path_set)
          pre_eval = publishable_pre_eval_constants(project_pre_eval_constants, discovery_seed,
                                                    project_constant_sources, pre_eval_path_set)
          literal = literal_seed_constants(project_constant_values, discovery_seed)
          return literal if pre_eval.empty?
          return pre_eval if literal.empty?

          pre_eval.merge(literal).freeze
        end

        # The project's literal constant table: this run's, or the one a `discovery_seed:` carries (ADR-124).
        def literal_seed_constants(project_constant_values, discovery_seed)
          return project_constant_values unless project_constant_values.empty? && discovery_seed

          discovery_seed.fetch(:in_source_constants, project_constant_values)
        end

        # The per-name writer paths the #663 retraction reads: this run's census, or the one a `discovery_seed:` carries
        # (ADR-124).
        def constant_writer_sources(project_constant_sources, discovery_seed)
          return project_constant_sources unless project_constant_sources.empty? && discovery_seed

          discovery_seed.fetch(:constant_sources, project_constant_sources)
        end

        # Issue #663 — the `pre_eval:` publication with every name an UNLISTED file also assigns retracted.
        # Without this a listed `X = :a` answered `Symbol` at every reader while a sibling `X = "str"` decided
        # the runtime value half the time: a confident wrong type, not lost precision, and the one asymmetry
        # #644's precedence work left standing. The retraction costs the opt-in nothing where it earns its
        # keep — a name only listed files write is untouched, and where the literal table also publishes it
        # already won (above).
        #
        # Conflict is read off #644's write attribution, which censuses every assigning form, so a name the
        # listed file's own typed walk widened is retracted by an unlisted `X += 1` or `A, X = 1, 2` as
        # readily as by a plain reassignment. Among LISTED files the rule is unchanged: `PreEvalConstants`
        # widens first and drops only on disagreement, so two listed files writing `1` and `2` still publish
        # `Integer` rather than being retracted for being two.
        def publishable_pre_eval_constants(project_pre_eval_constants, discovery_seed, project_constant_sources,
                                           pre_eval_path_set)
          return project_pre_eval_constants if project_pre_eval_constants.empty?

          listed = pre_eval_path_set
          kept = project_pre_eval_constants.reject do |name, _|
            unlisted_constant_writer?(name, listed, project_constant_sources, discovery_seed)
          end
          kept.size == project_pre_eval_constants.size ? project_pre_eval_constants : kept.freeze
        end

        # True when some file outside `listed` assigns `name`. The wildcard key is consulted alongside the
        # name's own attribution ([#668](https://github.com/rigortype/rigor/issues/668)): a `k::X = 7` names
        # no target, and a listed file kept out of `paths:` (ADR-17 WD5 permits it) contributes no censused
        # name of its own for the wildcard's paths to have been folded into.
        def unlisted_constant_writer?(name, listed, project_constant_sources, discovery_seed)
          segment = name.split("::").last
          sources = constant_writer_sources(project_constant_sources, discovery_seed)
          writers = sources[name]
          wildcard = sources["#{Inference::ScopeIndexer::DYNAMIC_TARGET_PREFIX}#{segment}"]
          [writers, wildcard].any? do |paths|
            paths&.any? { |path| !listed.include?(File.absolute_path(path)) }
          end
        end

        private_class_method :publishable_pre_eval_constants, :literal_seed_constants, :constant_writer_sources,
                             :unlisted_constant_writer?
      end
    end
  end
end
