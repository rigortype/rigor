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
      :program_global_seeds,
      :discovered_classes,
      :in_source_constants,
      :discovered_methods,
      :discovered_def_nodes,
      :discovered_def_nestings,
      :discovered_singleton_def_nodes,
      :discovered_def_sources,
      :discovered_singleton_def_sources,
      :discovered_method_visibilities,
      :discovered_parameter_envelopes,
      :discovered_superclasses,
      :discovered_deferred_ranges,
      :discovered_refinements,
      :discovered_header_nestings,
      :discovered_includes,
      :discovered_prepends,
      :discovered_extends,
      :discovered_class_sources,
      :constant_sources,
      :constant_writers,
      :constant_shadowers,
      :published_constant_names,
      :local_constant_names,
      :published_constant_alias_names,
      :published_constant_ivars,
      :data_member_layouts,
      :struct_member_layouts,
      :param_inferred_types,
      :run_generation,
      :patched_line_readers,
      :clears_last_status,
      :defines_case_equality
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

      # Issue #728 — the key a `discovered_header_nestings` bucket stores its class-wide chain under, beside
      # the per-ancestor-name entries. `nil` is used because every other key in a bucket is an ancestor name
      # as written, and no ancestor name can be nil.
      UNKEYED_HEADER_NESTING = nil

      # Issue #986 — a bucket entry is normally ONE chain (`["Wrap"]`, innermost first). When the
      # compact-header rename pass lands two declarations of one class on a single key and both wrote the
      # same raw ancestor name in DIFFERENT crefs, the entry is instead the LIST of those chains —
      # `[["Wrap"], []]` — because no union of them is Ruby's answer for either site. `Scope` resolves each
      # alternative and declines outright when they name two different project classes: which one wins
      # depends on the runtime load order of the two `include`s, which static analysis cannot know, so
      # picking either is unsound. A chain's entries are Strings and an alternatives list's are Arrays, so
      # the two shapes cannot be confused.
      def self.ambiguous_header_nesting?(entries)
        entries.first.is_a?(Array)
      end

      # Issue #992 — the two class-wide keys a `discovered_parameter_envelopes` bucket can carry beside its
      # `[kind, method_name]` entries. Their PRESENCE is the fact; the value is always
      # `Source::ParameterEnvelope::OPAQUE`, so a bucket folds under the one join every other entry does.
      # Symbols, because every per-method key is an Array and neither can collide with the other.
      #
      # - {ENVELOPE_MODULE_MARK}: the name is declared with `module` (or `Const = Module.new do … end`) somewhere
      #   in the project. An instance of it is an instance of an unknown includer.
      # - {ENVELOPE_DYNAMIC_MARK}: the class body rewrites its method table in a way no literal argument names
      #   (`class_eval`, a computed `define_method`, `send`, a non-constant mixin), or a constant-receiver form
      #   of those names it from outside.
      # - {ENVELOPE_OBJECT_EXTENDED_MARK}: some method body passes the module to `extend`, so an object of any
      #   class may carry its instance methods ahead of that class's own.
      ENVELOPE_MODULE_MARK = :"<module>"
      ENVELOPE_DYNAMIC_MARK = :"<dynamic>"
      ENVELOPE_OBJECT_EXTENDED_MARK = :"<object-extended>"

      # Issue #992 — the class key a WHOLE-PROJECT discovery pass adds to `discovered_parameter_envelopes`
      # (`ScopeIndexer#finalize_def_index`), with an empty bucket. A single file's walk alone — `run_source`,
      # the LSP `prebuilt:` scope — sees one `def` and cannot see the reopening, subclass or `class_eval` in
      # another file that would make it opaque, so `call.wrong-arity` reads an envelope only when this key is
      # present. Not a constant character, so no class can be named it.
      ENVELOPE_PROJECT_WIDE = "<project-wide>"

      # The shared all-empty index `Scope.empty` (and every scope that never sees a seeding pass) points at — one
      # allocation per process.
      EMPTY = new(
        declared_types: EMPTY_NODE_TABLE,
        class_ivars: EMPTY_TABLE,
        class_cvars: EMPTY_TABLE,
        program_globals: EMPTY_TABLE,
        # Issue #1362 — `program_globals`, the union of each global's writes in the file, joined with the declared
        # type of a global Ruby's own signatures declare (`$VERBOSE: bool?`, `$stdout: IO`): what every method body and
        # the top level start from. `program_globals` keeps the writes alone for the checks that ask what the file
        # writes (`$;` for `split`). Filled by `Inference::ScopeIndexer.index` from the file's own tree only.
        program_global_seeds: EMPTY_TABLE,
        discovered_classes: EMPTY_TABLE,
        in_source_constants: EMPTY_TABLE,
        discovered_methods: EMPTY_TABLE,
        discovered_def_nodes: EMPTY_TABLE,
        # Issue #681 — `{Prism::DefNode => Module.nesting}` for every `def` the declaration walk reaches,
        # recorded by `Inference::ScopeIndexer` where the declaration is indexed. Read by
        # `Inference::ExpressionTyper#build_user_method_body_scope`, which rebuilds a callee's body scope
        # from the receiver's type alone and so has no prefix of its own to derive one from. Keyed by node
        # IDENTITY, because an inherited body is re-walked with the subclass as receiver while its
        # constants resolve under the declaration that owns it.
        #
        # Issue #716 — PRESENT with `[]` and ABSENT are different facts, and only this table can tell them
        # apart: it is populated by the declaration walk alone, so `[]` means "walked, and written at the top
        # level" (Ruby's `Module.nesting` there) while an absent entry still means "not recorded" and
        # `Reflection.lexical_nesting_chain` keeps its peel fallback for it.
        discovered_def_nestings: EMPTY_NODE_TABLE,
        discovered_singleton_def_nodes: EMPTY_TABLE,
        discovered_def_sources: EMPTY_TABLE,
        discovered_singleton_def_sources: EMPTY_TABLE,
        discovered_method_visibilities: EMPTY_TABLE,
        # Issue #992 — `{qualified class name => {[kind, method_name] => Source::ParameterEnvelope}}`, the
        # parameter envelope of every method the declaration walk records, plus {ENVELOPE_MODULE_MARK} /
        # {ENVELOPE_DYNAMIC_MARK}. Written beside `discovered_methods` by one recorder, so an `alias` / `attr_*`
        # / `define_method` name is always present here as `OPAQUE`, and folded across files and reopenings
        # with `Source::ParameterEnvelope.merge`: one value per name, a real envelope only while every
        # contribution agrees. Read by `call.wrong-arity` for a method no signature declares.
        discovered_parameter_envelopes: EMPTY_TABLE,
        discovered_superclasses: EMPTY_TABLE,
        # Issue #1097 — `{file path => [[start_offset, end_offset, name, kind, owner], ...]}`, every
        # `def` / block / lambda body range in the file. `Scope#*_def_shadows_call?` reads it to tell
        # an eager class-body call (orderable by offset against a same-name, same-owner def entry)
        # from a deferred one (contained in any range — it runs at invocation time, when every
        # class-body def exists). Def entries carry the method name, the `:instance` / `:singleton` /
        # `:both` (module_function) kind, and the qualified owner; block / lambda rows and defs nested
        # inside another deferred range carry nils and answer only the containment half. Plain data,
        # so the ADR-85 seed bundle round-trips it unchanged.
        discovered_deferred_ranges: EMPTY_TABLE,
        # Issue #1120 — `{refined class name => {method name => [refining module names]}}`, the instance
        # methods a `refine X do … end` block defines. They are not X's methods everywhere: Ruby activates them
        # only lexically after a `using` of the refining module, so `call.undefined-method` reads this table
        # together with the call site's file ({Analysis::CheckRules::LexicalMethodSites}) and never through
        # `discovered_methods`. A refinement a `Module.new { … }` block defines has no nameable module; it is
        # keyed by the name the walk gives the block's owner. Plain data, so the ADR-85 seed bundle
        # round-trips it unchanged.
        discovered_refinements: EMPTY_TABLE,
        # Issue #682 — `{qualified class name => Module.nesting where its declaration HEADER is written}`,
        # innermost first and EXCLUDING the declaration's own entry. Read by `Scope#ancestor_name_candidates`,
        # which resolves a superclass / include name in that cref instead of peeling the subclass's qualified
        # name — the peel is the nested spelling's answer, and it searched an `Admin::Base` that a compact
        # `class Admin::Widget < Base` written at the top level never reaches. An absent entry means "not
        # recorded" and keeps the peel, so a scope that never saw a declaration walk is unchanged.
        #
        # Issue #728 — the value is keyed by the ancestor NAME the site wrote, because a class's declaration
        # sites need not share a cref: `class Foo < Base` at the top level and `class ::Foo; include Helper`
        # inside `module Outer` resolve `Base` and `Helper` in different ones, and a single chain per class
        # gave `Outer` to both. {UNKEYED_HEADER_NESTING} holds the union over every ancestor-naming site, for
        # a name no site recorded under its own key.
        discovered_header_nestings: EMPTY_TABLE,
        discovered_includes: EMPTY_TABLE,
        # Issue #1123 — `{qualified class or module name => [module names it `prepend`s, as written]}`,
        # stored in instance-ancestor SEARCH order (nearest prepend first), the `discovered_extends`
        # convention. The instance-side twin `discovered_includes` holds the same names — prepends
        # included — in that order too since #1173: prepends ahead of includes, each nearest-first. The
        # kind still cannot be told apart there, so `Scope#user_def_through_ancestors` reads the wedge
        # from here. An absent entry means "prepends nothing", which is the un-preprended behaviour
        # every scope had before it existed.
        discovered_prepends: EMPTY_TABLE,
        # Issue #898 — the singleton-side twin of `discovered_includes`: `{qualified class or module name =>
        # [module names it `extend`s, as written]}`, built by the same `ScopeIndexer` walk that #526 already
        # ran to fold an extended module's instance defs onto the extending class's singleton. #526 consumed
        # the table inside the indexer and threw it away; `Narrowing` needs it to survive onto the scope,
        # because `Singleton[C]`'s ancestry is exactly what `extend` writes and nothing else records it.
        discovered_extends: EMPTY_TABLE,
        discovered_class_sources: EMPTY_TABLE,
        # Issue #644 — `{qualified constant name => Set[declaring file]}`, the write attribution behind the
        # cross-file value-constant table. Read only by `Scope#record_constant_dependency` during ADR-46
        # dependency recording, so the runner seeds it only on a recording run; every other run leaves it
        # empty and the edge costs one nil check.
        constant_sources: EMPTY_TABLE,
        # Issue #617 — the censused names that bind (any write other than a memo `||=`, or memos of the
        # segment in two files), grouped by LAST SEGMENT, wildcard keys (`*::LIMIT`) under their segment.
        # `Scope#bound_constant_names` reads it for a constant compound write whose plain read resolves to
        # nothing: such a name is bound, just not to a value the analyzer carries. Seeded on every run, because
        # the question is a typing one rather than a recording one.
        constant_writers: EMPTY_TABLE,
        # Issue #1290 — the censused names some write other than a memo `||=` assigns, grouped by LAST SEGMENT.
        # `Scope#shadowing_constant_names` reads it for the lexical ladder: a candidate no source types but this
        # table holds is where Ruby's lookup stops. Seeded on every run beside `constant_writers`.
        constant_shadowers: EMPTY_TABLE,
        # Issue #644 — the two halves of `Scope#published_constant?`, the question
        # {Analysis::CheckRules::PublishedConstantGuard} asks. `published_constant_names` is the LAST
        # SEGMENTS of the project-wide published table (run-wide, seeded by the runner);
        # `local_constant_names` is the last segments the ANALYSED FILE itself assigns (per file, seeded by
        # `ScopeIndexer.index`). A name in the first and not the second was declared somewhere the reader's
        # author cannot see. Both empty outside a runner-seeded scope, which makes the guard a no-op there.
        published_constant_names: EMPTY_NAME_SET,
        local_constant_names: EMPTY_NAME_SET,
        # Issue #667 — the two per-file tables that carry a published constant's provenance across a COPY,
        # which the name sets above cannot: they answer about a reference's spelling, and a copy has none.
        # `published_constant_alias_names` is the last segments of the constants THIS FILE assigns straight
        # from a foreign published one (`MODE2 = AppConfig::MODE`), which the local-declaration exemption
        # would otherwise release. `published_constant_ivars` is `{class name => Set[ivar name]}` for an ivar
        # whose class-ivar seed is such a copy (`@mode = AppConfig::MODE` in `initialize`), stamped onto the
        # flow carrier at method entry. Both are seeded by `ScopeIndexer.index` and only when the project
        # published something, so a project with no cross-file value constants pays no walk.
        published_constant_alias_names: EMPTY_NAME_SET,
        published_constant_ivars: EMPTY_TABLE,
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
        run_generation: nil,
        # Issue #1359 — the `gets` / `readline` names this file patches in through the `define_method` family
        # (`$stdin.define_singleton_method(:gets) { … }`, `IO.define_method(:gets)`, `alias_method :gets, :x`, or a
        # computed name, which may be either), which `Inference::LastLine.reads_line?` declines on, as it does on a
        # name `BlockCallTiming.project_defines_anywhere?` finds. Filled by `Inference::ScopeIndexer.index` from the
        # file's own tree only.
        patched_line_readers: EMPTY_NAME_SET,
        # Issue #1360 — true when this file holds a call that may set `$?` to nil (`Inference::LastStatus.clears?`: a
        # `wait`-family call with a flags argument, or `waitall`), which may run between any subprocess and a read of
        # `$?`, so `Inference::LastStatus.after` binds it nowhere in the file. Filled by `Inference::ScopeIndexer.index`
        # from the file's own tree only.
        clears_last_status: false,
        # Issue #1360 — true when this file holds a `define_method` or `define_singleton_method` call whose literal
        # name is `===` (`Inference::ErrorInfo.defines_case_equality?`), which may give a class the singleton `===`
        # `rescue` matches with; the class it lands on is not recorded, so no rescued class binds `$!` in the file.
        # Filled by `Inference::ScopeIndexer.index` from the file's own tree only.
        defines_case_equality: false
      )
    end
  end
end
