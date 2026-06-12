# frozen_string_literal: true

module Rigor
  class Scope
    # ADR-53 Track A — the seed-time discovery context every Scope snapshot
    # carries by a single reference. Holds the tables the index-time
    # pre-passes (`Inference::ScopeIndexer` per file, plus the cross-file
    # project pre-pass) populate and that no control-flow transition ever
    # varies: `Scope#==` ignores them and `Scope#join` copies them from the
    # receiver unexamined, which is the membership litmus the ADR fixes.
    #
    # Immutable (`Data` instances are frozen); deriving a seeded index goes
    # through `#with(table_name: table)`. `Scope` exposes each table through
    # its existing reader surface, so engine call sites and plugins are
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
      :data_member_layouts
    )

    class DiscoveryIndex
      EMPTY_NODE_TABLE = {}.compare_by_identity.freeze
      EMPTY_TABLE = {}.freeze
      private_constant :EMPTY_NODE_TABLE, :EMPTY_TABLE

      # The shared all-empty index `Scope.empty` (and every scope that never
      # sees a seeding pass) points at — one allocation per process.
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
        data_member_layouts: EMPTY_TABLE
      )
    end
  end
end
