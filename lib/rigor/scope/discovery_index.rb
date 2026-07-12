# frozen_string_literal: true

module Rigor
  class Scope
    # ADR-53 Track A — the seed-time discovery context every Scope snapshot carries by a single reference. Holds
    # the tables the index-time pre-passes (`Inference::ScopeIndexer` per file, plus the cross-file project
    # pre-pass) populate and that no control-flow transition ever varies: `Scope#==` ignores them and
    # `Scope#join` copies them from the receiver unexamined, which is the membership litmus the ADR fixes.
    #
    # Immutable (`Data` instances are frozen); deriving a seeded index goes through `#with(table_name: table)`.
    # `Scope` exposes each table through its existing reader surface, so engine call sites and plugins are
    # unaffected by the extraction.
    DiscoveryIndex = Data.define(
      :declared_types,
      :class_ivars,
      :class_cvars,
      :program_globals,
      :discovered_classes,
      :in_source_constants,
      :discovered_methods,
      :discovered_def_nodes,
      :discovered_singleton_def_nodes,
      :discovered_def_sources,
      :discovered_method_visibilities,
      :discovered_superclasses,
      :discovered_includes,
      :discovered_class_sources,
      :data_member_layouts,
      :struct_member_layouts,
      :param_inferred_types,
      :run_generation
    )

    class DiscoveryIndex
      EMPTY_NODE_TABLE = {}.compare_by_identity.freeze
      EMPTY_TABLE = {}.freeze
      private_constant :EMPTY_NODE_TABLE, :EMPTY_TABLE

      # The shared all-empty index `Scope.empty` (and every scope that never sees a seeding pass) points at — one
      # allocation per process.
      EMPTY = new(
        declared_types: EMPTY_NODE_TABLE,
        class_ivars: EMPTY_TABLE,
        class_cvars: EMPTY_TABLE,
        program_globals: EMPTY_TABLE,
        discovered_classes: EMPTY_TABLE,
        in_source_constants: EMPTY_TABLE,
        discovered_methods: EMPTY_TABLE,
        discovered_def_nodes: EMPTY_TABLE,
        discovered_singleton_def_nodes: EMPTY_TABLE,
        discovered_def_sources: EMPTY_TABLE,
        discovered_method_visibilities: EMPTY_TABLE,
        discovered_superclasses: EMPTY_TABLE,
        discovered_includes: EMPTY_TABLE,
        discovered_class_sources: EMPTY_TABLE,
        data_member_layouts: EMPTY_TABLE,
        struct_member_layouts: EMPTY_TABLE,
        # ADR-67 WD3 — the call-site parameter-inference table, keyed by `[class_name, method_name, kind]` (the
        # same `(class, method, kind)` triple {Inference::ParameterInferenceCollector} records and that
        # `build_method_entry_scope` reconstructs from the lexical class path). The value is a
        # `{param_name(Symbol) => Rigor::Type}` map of the union of resolved call-site argument types. Empty on
        # every normal run; only the `coverage --protection` collection pass populates it today, so a `check` run
        # leaves it empty and seeds nothing (byte-identical).
        param_inferred_types: EMPTY_TABLE,
        # ADR-84 WD2 — the run-scope identity token `Analysis::Runner#run_analysis` mints per run (a frozen
        # bare Object) and seeds through `project_scope_seed_tables`. The user-method return memo keys its
        # bucket on this token's identity so hits cross consumer-file boundaries within one run but never
        # cross a run boundary (LSP / ADR-62 warm-loop re-runs land in a fresh bucket). Nil on scopes that
        # never see the runner seed (single-file probes, `run_source` before the seed applies): the memo
        # falls back to today's per-file `discovered_def_nodes` identity for those.
        run_generation: nil
      )
    end
  end
end
