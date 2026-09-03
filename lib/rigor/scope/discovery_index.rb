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
      :discovered_def_nestings,
      :discovered_singleton_def_nodes,
      :discovered_def_sources,
      :discovered_singleton_def_sources,
      :discovered_method_visibilities,
      :discovered_superclasses,
      :discovered_header_nestings,
      :discovered_includes,
      :discovered_class_sources,
      :constant_sources,
      :published_constant_names,
      :local_constant_names,
      :data_member_layouts,
      :struct_member_layouts,
      :param_inferred_types,
      :run_generation
    )

    class DiscoveryIndex
      EMPTY_NODE_TABLE = {}.compare_by_identity.freeze
      EMPTY_TABLE = {}.freeze
      EMPTY_NAME_SET = Set.new.freeze
      private_constant :EMPTY_NODE_TABLE, :EMPTY_TABLE, :EMPTY_NAME_SET

      # The third value a `discovered_methods` entry can hold, beside `:instance` and `:singleton`. One name may
      # legitimately be defined on both sides of the same class (`def helper` plus a `class << self` twin), and the
      # table is keyed by name alone — so before this existed the second `def` overwrote the first's kind and
      # `Scope#discovered_method?` answered false for a method that is right there in the source. That is a false
      # `call.undefined-method` on ordinary Ruby (#239), which outranks any worst-case reading (AGENTS.md
      # § "Implementation Guidelines"). Writers promote to this instead of clobbering; readers treat it as matching
      # either kind.
      METHOD_KIND_BOTH = :both

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
        # Issue #681 — `{Prism::DefNode => Module.nesting}` for every `def` declared inside a class or
        # module body, recorded by `Inference::ScopeIndexer` where the declaration is indexed. Read by
        # `Inference::ExpressionTyper#build_user_method_body_scope`, which rebuilds a callee's body scope
        # from the receiver's type alone and so has no prefix of its own to derive one from. Keyed by node
        # IDENTITY, because an inherited body is re-walked with the subclass as receiver while its
        # constants resolve under the declaration that owns it. An absent entry means "not recorded", and
        # `Reflection.lexical_nesting_chain` keeps its peel fallback for it.
        discovered_def_nestings: EMPTY_NODE_TABLE,
        discovered_singleton_def_nodes: EMPTY_TABLE,
        discovered_def_sources: EMPTY_TABLE,
        discovered_singleton_def_sources: EMPTY_TABLE,
        discovered_method_visibilities: EMPTY_TABLE,
        discovered_superclasses: EMPTY_TABLE,
        # Issue #682 — `{qualified class name => Module.nesting where its declaration HEADER is written}`,
        # innermost first and EXCLUDING the declaration's own entry. Read by `Scope#ancestor_name_candidates`,
        # which resolves a superclass / include name in that cref instead of peeling the subclass's qualified
        # name — the peel is the nested spelling's answer, and it searched an `Admin::Base` that a compact
        # `class Admin::Widget < Base` written at the top level never reaches. An absent entry means "not
        # recorded" and keeps the peel, so a scope that never saw a declaration walk is unchanged.
        discovered_header_nestings: EMPTY_TABLE,
        discovered_includes: EMPTY_TABLE,
        discovered_class_sources: EMPTY_TABLE,
        # Issue #644 — `{qualified constant name => Set[declaring file]}`, the write attribution behind the
        # cross-file value-constant table. Read only by `Scope#record_constant_dependency` during ADR-46
        # dependency recording, so the runner seeds it only on a recording run; every other run leaves it
        # empty and the edge costs one nil check.
        constant_sources: EMPTY_TABLE,
        # Issue #644 — the two halves of `Scope#published_constant?`, the question
        # {Analysis::CheckRules::PublishedConstantGuard} asks. `published_constant_names` is the LAST
        # SEGMENTS of the project-wide published table (run-wide, seeded by the runner);
        # `local_constant_names` is the last segments the ANALYSED FILE itself assigns (per file, seeded by
        # `ScopeIndexer.index`). A name in the first and not the second was declared somewhere the reader's
        # author cannot see. Both empty outside a runner-seeded scope, which makes the guard a no-op there.
        published_constant_names: EMPTY_NAME_SET,
        local_constant_names: EMPTY_NAME_SET,
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
