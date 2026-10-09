# frozen_string_literal: true

require_relative "type"
require_relative "environment"
require_relative "scope/discovery_index"
require_relative "scope/resolution_chain"
require_relative "inference/definer_resolution"
require_relative "inference/in_effect_refinements"
require_relative "analysis/fact_store"
require_relative "analysis/dependency_recorder"
require_relative "inference/expression_typer"
require_relative "inference/flow_tracer"
require_relative "inference/optimistic_origin"
require_relative "inference/statement_evaluator"
require_relative "inference/def_node_resolver"

module Rigor
  # Immutable analyzer scope: holds local-variable bindings and a reference to the surrounding Environment. State
  # changes return new scopes through explicit transition methods (#with_local). The central query is
  # #type_of(node), the Rigor counterpart of PHPStan's $scope->getType($node).
  #
  # See docs/internal-spec/inference-engine.md for the binding contract.
  # rubocop:disable-next Metrics/ClassLength,Metrics/ParameterLists
  class Scope
    attr_reader :environment, :locals, :fact_store, :self_type,
                :ivars, :cvars, :globals,
                :indexed_narrowings, :method_chain_narrowings,
                :declaration_sourced, :published_constant_sourced,
                :source_path, :discovery, :struct_fold_safe_locals,
                :opaque_block_self, :singleton_class_body, :lexical_nesting,
                :dynamic_origins, :local_origins, :ivar_origins,
                :void_origins, :plugin_typed_calls,
                :optimistic_origins, :optimistic_locals, :optimistic_ivars,
                :repeated_or_writes, :match_frame,
                :constant_narrowings, :guard_records, :bot_guard_classes

    # ADR-53 Track A — the seed-time discovery tables live on the {DiscoveryIndex} the scope carries by a single
    # reference; the per-table readers stay on Scope so engine call sites and plugins are unaffected by the
    # extraction. The whole index is swapped in one transition through {#with_discovery}.
    #
    # `declared_types` carries the identity-comparing `Prism::Node => Rigor::Type` declaration overrides
    # `ExpressionTyper#type_of(node)` MUST consult before any other dispatch (a `module Foo` / `class Bar` header
    # types as `Singleton[<qualified path>]` rather than `Dynamic[Top]`).
    def declared_types = @discovery.declared_types
    def class_ivars = @discovery.class_ivars
    def class_cvars = @discovery.class_cvars
    def program_globals = @discovery.program_globals
    def discovered_classes = @discovery.discovered_classes
    def in_source_constants = @discovery.in_source_constants
    def discovered_methods = @discovery.discovered_methods
    def discovered_def_nodes = @discovery.discovered_def_nodes
    def discovered_singleton_def_nodes = @discovery.discovered_singleton_def_nodes
    def discovered_def_sources = @discovery.discovered_def_sources
    def discovered_singleton_def_sources = @discovery.discovered_singleton_def_sources
    def discovered_method_visibilities = @discovery.discovered_method_visibilities
    def discovered_parameter_envelopes = @discovery.discovered_parameter_envelopes
    def discovered_superclasses = @discovery.discovered_superclasses

    # Issue #1097 — `{file path => [[start_offset, end_offset, name, kind, owner], ...]}`, the def /
    # block / lambda body ranges {singleton_def_shadows_call?} / {instance_def_shadows_call?} order a
    # project-defined override against.
    def discovered_deferred_ranges = @discovery.discovered_deferred_ranges
    # Issue #1120 — `{refined class name => {method name => [refining module names]}}`: what each
    # `refine X do … end` block defines, visible only where a `using` of its module is in effect.
    def discovered_refinements = @discovery.discovered_refinements

    # Issue #1673 (ADR-121 WD1) — the in-effect refinements at `node`: the refining-module names whose refinements
    # Ruby applies there, ordered so a later activation comes later (the later one wins), each once at its first
    # position, each `using`'d module expanded through its includes and prepends in CRuby's activation order.
    # `declared` is a block source's modules, appended and expanded on the same terms: a plugin-declared refined
    # block's (#1667). An entry may be
    # `Inference::InEffectRefinements::UNKNOWN`, which means any refinement may be in effect. A node another file
    # wrote (a callee body typed under this file's scope) answers `declared` alone. Reads include edges, so it records
    # the dependencies `Inference::InEffectRefinements.activated_modules` names; a consumer that asks for a method
    # name also records `refinement:<name>` (`Inference::InEffectRefinements.refining_modules`).
    def in_effect_refinements(node, declared = Inference::InEffectRefinements::EMPTY)
      Inference::InEffectRefinements.for_node(self, node, declared)
    end

    # Issue #1367 — the project's `Inference::GlobalWriteCensus`, a `Set` of frozen entries.
    def discovered_global_write_census = @discovery.discovered_global_write_census
    def discovered_includes = @discovery.discovered_includes
    # Issue #1123 — `{qualified class or module name => [module names it `prepend`s, as written]}`, in
    # instance-ancestor search order (nearest prepend first). The one table that tells a `prepend` from an
    # `include`: {ResolutionChain} reads it to put a prepended module ahead of the class.
    # The plugin-facing view: each class's prepends once, nearest first. The discovery index itself keeps every
    # statement (a repeated `prepend` is a no-op in Ruby, the first statement winning), and the resolution chain
    # reads that raw list.
    def discovered_prepends = @discovery.discovered_prepends.transform_values { |names| names.uniq.freeze }.freeze
    def discovered_extends = @discovery.discovered_extends
    def discovered_class_sources = @discovery.discovered_class_sources
    # Issue #644 — `{qualified constant name => Set[declaring file]}`; seeded only on an ADR-46 recording run.
    def constant_sources = @discovery.constant_sources
    def published_constant_names = @discovery.published_constant_names
    def local_constant_names = @discovery.local_constant_names

    # Issue #617 — the census names sharing `name`'s last segment that bind, spelled as the census spells
    # them (a `*::LIMIT` wildcard included), so the caller still decides which of them a reference resolves
    # to. A `||=`-only name is left out while no other file memoizes its segment: the memoization idiom's
    # own write, however often one file repeats it, is not what binds it.
    def bound_constant_names(name)
      @discovery.constant_writers[name.split("::").last] || EMPTY_BOUND_CONSTANT_NAMES
    end

    # Issue #1290 — the census names sharing `name`'s last segment that some write other than a memo `||=`
    # assigns: the ones that shadow an outer constant of the name, so the lexical ladder stops at them
    # (`Reflection.resolve_constant_type`). That asks once per constant reference, so a bare name is looked up
    # as it stands rather than split, and a qualified one is sliced after its last `::` rather than split into
    # an Array of every segment ([#1502](https://github.com/rigortype/rigor/issues/1502)). The two agree on every
    # name a parsed constant path spells. Only the `Foo::` Prism recovers from a syntax error differs, and no
    # file with a parse error is typed.
    def shadowing_constant_names(name)
      separator = name.rindex("::")
      segment = separator ? name[(separator + 2)..] : name
      @discovery.constant_shadowers[segment] || EMPTY_BOUND_CONSTANT_NAMES
    end

    EMPTY_BOUND_CONSTANT_NAMES = [].freeze
    private_constant :EMPTY_BOUND_CONSTANT_NAMES

    # Issue #667 — the instance-variable names of `class_name` whose class-ivar seed comes from a foreign
    # published constant (`@mode = AppConfig::MODE` in `initialize`, read in a sibling method).
    # `StatementEvaluator#seed_instance_ivars` stamps the flow mark for these at method-body entry, the way
    # ADR-58's seed stamps its own; a method-local write or narrowing then drops it through `with_ivar`.
    def published_constant_ivars_for(class_name)
      @discovery.published_constant_ivars[class_name] || EMPTY_PUBLISHED_CONSTANT_IVARS
    end

    # Issue #644 — true when the constant reference `name` (as written: `MODE` or `AppConfig::MODE`) is
    # published by the cross-file value-constant table and is NOT assigned by the file being analysed: a
    # value this file's author cannot see the declaration of. {Analysis::CheckRules::PublishedConstantGuard}
    # is the only caller — a rule MUST ask through the guard rather than re-derive the question here, exactly
    # as ADR-58's mark is asked through `DeclarationSourcedGuard`.
    #
    # The two halves match at deliberately different granularities, because the two errors are not
    # symmetric. The PUBLISHED half matches on the last segment and so over-answers (a reader of a nested
    # `MyApp::MODE` answers true for a top-level `MODE`) — over-answering only ever WITHHOLDS a firing, the
    # safe direction, and it is the grammar the ADR-46 negative keys already use. The LOCAL half is an
    # exemption, so over-answering there would UN-withhold: matching it on the last segment too would let an
    # unrelated `Local::MODE` in this file make a read of `AppConfig::MODE` fire.
    #
    # The exemption therefore matches a **suffix relation on qualified names**, not the spelling and not the
    # last segment: a local assignment exempts a reference when it IS that reference or ENDS with `::` plus
    # it. That is what a lexically relative spelling resolves to — inside `module AppConfig`, the reference
    # `Nested::X` is the file's own `AppConfig::Nested::X` — and it subsumes the bare case (`OWNED` matched
    # by `Owner::OWNED`) without matching the unrelated `Local::MODE` above. It is deliberately a relation
    # over already-qualified names rather than a second lexical ladder: the engine's ladder
    # (`Reflection.resolve_constant_type`) answers with a TYPE and not with the candidate that won, and
    # reimplementing the walk here is the very thing that made the receiver resolution wrong once already.
    #
    # Issue #667 — a third answer sits beside those two. `MODE2 = AppConfig::MODE` is assigned by this file,
    # so the exemption above releases it, yet its value is still one the author never saw: the alias only
    # renames the foreign declaration. `published_constant_alias_names` holds the last segments of exactly
    # those aliases, and matching on the last segment over-answers in the WITHHOLDING direction, which is the
    # safe one.
    def published_constant?(name)
      names = @discovery.published_constant_names
      return true if published_constant_alias?(name)
      return false if names.empty?
      return false unless names.include?(name.split("::").last)

      !locally_declared_constant?(name)
    end

    def published_constant_alias?(name)
      aliases = @discovery.published_constant_alias_names
      !aliases.empty? && aliases.include?(name.split("::").last)
    end
    private :published_constant_alias?

    def locally_declared_constant?(reference_name)
      local = @discovery.local_constant_names
      return false if local.empty?
      return true if local.include?(reference_name)

      suffix = "::#{reference_name}"
      local.any? { |name| name.end_with?(suffix) }
    end
    private :locally_declared_constant?

    def data_member_layouts = @discovery.data_member_layouts
    def struct_member_layouts = @discovery.struct_member_layouts
    # ADR-67 WD3 — call-site-inferred parameter types, keyed by `[class_name, method_name, kind]`.
    # `build_method_entry_scope` consults this to seed an undeclared `def` parameter with the union of its resolved
    # call-site argument types (precision-additive; an RBS-declared parameter always wins). Empty unless a
    # collection pass seeded it.
    def param_inferred_types = @discovery.param_inferred_types
    # ADR-84 WD2 — the per-run identity token the user-method return memo buckets on (nil outside runner-seeded
    # scopes; the memo then falls back to the per-file `discovered_def_nodes` identity).
    def run_generation = @discovery.run_generation

    # Narrowing key for an indexed read `receiver[key]` where both the receiver and the key are stable enough to
    # address. The value of the map at this key is the narrowed type the next read at the same address MUST
    # observe.
    #
    # - `receiver_kind` ∈ `{:local, :ivar}` — the analyzer only tracks reads against a local or instance variable
    #   today.
    # - `receiver_name` is the variable's Symbol.
    # - `key` is the Ruby value of the literal index (Symbol / String / Integer). Non-literal keys
    #   (`params[field]`) have no stable address for a recorded value. A `key?` guard with a non-literal key
    #   (issue #1703) records an {Inference::KeyPresenceGuard::KeyExpr} here instead, with `receiver_kind`
    #   `:const` allowed; its entry marks presence only.
    IndexedKey = Data.define(:receiver_kind, :receiver_name, :key)

    # Narrowing key for a no-arg / no-block method-call chain `receiver.method_name` (a "single-hop" chain per A1
    # from the ROADMAP § Future cycles slice). The value of the map at this key is the narrowed type the next read
    # of the same chain MUST observe — typically the post-`is_a?(C)` narrowing established on a predicate edge.
    #
    # - `receiver_kind` ∈ `{:local, :ivar}` — the analyzer only tracks chains rooted at a local or instance
    #   variable today (Law-of-Demeter-style single-hop).
    # - `receiver_name` is the root variable's Symbol.
    # - `method_name` is the no-arg method invoked on the root.
    #
    # Chains with arguments (`x.first(3)`), with a block (`x.detect { ... }`), or with intermediate links
    # (`x.foo.bar`) are NOT recorded; each loses stability for different reasons (args / block alter the call's
    # return; multi-hop loses the LoD guarantee).
    ChainKey = Data.define(:receiver_kind, :receiver_name, :method_name)

    EMPTY_VAR_BINDINGS = {}.freeze
    EMPTY_INDEXED_NARROWINGS = {}.freeze
    EMPTY_CHAIN_NARROWINGS = {}.freeze
    # ADR-58 WD1 — the set of variable references whose binding's `nil` constituent is *declaration-sourced*: it
    # arrives only via the class-ivar index seed (a ctor `@x = nil` written in another method), never through a
    # method-local write, narrowing, or parameter. Members are frozen `[kind, name]` pairs (`[:ivar, :@x]`,
    # `[:local, :r]`). `possible-nil-receiver` consults this set and declines to fire when the receiver's
    # optionality is purely declaration-sourced — the working program's cross-method invariant is assumed per the
    # robustness principle. Any flow-live touch (write / narrowing) drops the mark, so the diagnostic keeps firing
    # exactly as before on flow-observed nil.
    EMPTY_DECLARATION_SOURCED = Set.new.freeze
    # ADR-48 Struct slice 3 — the per-body set of local names whose struct member reads are fold-safe (provably
    # never mutated / aliased / escaped). A static per-scope context like {#source_path}: inherited unchanged
    # through flow transitions and ignored by `==` / `hash`.
    EMPTY_FOLD_SAFE = Set.new.freeze
    # ADR-82 WD1 — provenance propagation across the receiver-node lookup. `local_origins` / `ivar_origins`
    # map a `name` (Symbol) to the {Inference::DynamicOrigin} cause of the `Dynamic` value currently bound to
    # it, so a downstream dispatch whose receiver is a bare `x` / `@x` read resolves to why that value is
    # dynamic (the cause was recorded on the *assignment*'s rhs node, which the receiver-read node is not).
    # Advisory metadata like {#dynamic_origins}: ignored by `==` / `hash` (never varies a flow decision) and
    # threaded by reference through transitions; reset per method body (a fresh entry scope drops it), so the
    # name keys never collide across bodies.
    EMPTY_ORIGINS = {}.freeze
    # Issue #667 — the set of variable references currently bound to a value COPIED out of a constant the
    # project published and this file does not declare. Members are frozen `[kind, name]` pairs, the same
    # spelling {EMPTY_DECLARATION_SOURCED} uses, but a DELIBERATELY SEPARATE carrier: this mark joins by
    # UNION where ADR-58's kinds intersect, and it answers a different question (what a value's *constancy*
    # rests on, not what a binding's *optionality* rests on) for a different consumer. Folding it into the
    # ADR-58 set would be the third establishing transition its *Non-transitivity* passage reserves as a
    # decision, on a Set that already carries two opposite join policies.
    EMPTY_PUBLISHED_CONSTANT_SOURCED = Set.new.freeze
    # Issue #667 — the empty answer of {#published_constant_ivars_for}, so a class with no such ivar (every
    # class in a project that publishes nothing) allocates none.
    EMPTY_PUBLISHED_CONSTANT_IVARS = Set.new.freeze
    # The index `||=` sites of a repeating block body whose slot an earlier run of the body may have filled,
    # keyed by node identity and laid by a block-return pass at the body's entry
    # ({#with_repeated_or_writes}; `Inference::RepeatedOrWrites` decides which). The memoizing `||=` reading
    # (`StatementEvaluator#index_compound_write_value`) is withheld at such a site. The mark belongs to the
    # site, so no rebind or narrowing of a variable drops it, and a join keeps a site either arm holds: the
    # mark only ever withholds that reading, whose answer is the narrower one.
    EMPTY_REPEATED_OR_WRITES = {}.compare_by_identity.freeze
    # Issue #1429 — the narrowing a guard leaves on a constant reference (`STDOUT.is_a?(StringIO)`, `if CONFIG`),
    # keyed by the reference's spelling ({Inference::Narrowing.constant_key}: `"STDOUT"`, `"::Foo::BAR"`). A constant
    # has no binding of its own in the scope, so the table is what a read in the guarded edge answers
    # (`ExpressionTyper#type_of_constant_read`); a spelling it does not hold resolves as before.
    EMPTY_CONSTANT_NARROWINGS = {}.freeze
    # Issue #1429 — what each global and constant a guard narrowed was bound to before the guard, keyed
    # `[:global, :$name]` / `[:constant, key]`. Ruby may rebind a global (or `const_set` a constant) whenever code the
    # analysis cannot see runs, so a call or block that may run project or unresolved code restores each recorded
    # binding to the union of this pre-guard type and its narrowed one ({#forget_guard_narrowings}). A write drops
    # the record ({#with_global}), and a name the frame-local special-variable machinery owns is never recorded.
    # Issue #1446 — a class guard's narrowing of an instance variable is recorded too, keyed `[:ivar, :@name]`
    # ({#with_guarded_ivar}), since that code may reach `self` and rebind it; a write drops it ({#without_ivar_guard}).
    EMPTY_GUARD_RECORDS = {}.freeze
    # Issue #1446 — the classes a class guard narrowed a receiver to where the narrowing left it `bot`, keyed like
    # {EMPTY_GUARD_RECORDS} with `[:local, :name]` too: `return unless @cb.is_a?(Proc)` binds `@cb` to `bot` when the
    # guard is disjoint from its binding, but the value that passes it is a `Proc` (or a subclass of one), and a call
    # on it dispatches on that class. `Inference::GuardRebinding` reads the class a `bot` receiver runs its methods
    # on from here ({#bot_guard_classes_for}); a `bot` no class guard produced has no entry. A write or another
    # narrowing of the name drops its entry, and a join keeps one only both arms hold.
    EMPTY_BOT_GUARD_CLASSES = {}.freeze
    private_constant :EMPTY_VAR_BINDINGS, :EMPTY_INDEXED_NARROWINGS,
                     :EMPTY_CHAIN_NARROWINGS, :EMPTY_DECLARATION_SOURCED,
                     :EMPTY_FOLD_SAFE, :EMPTY_ORIGINS, :EMPTY_PUBLISHED_CONSTANT_SOURCED,
                     :EMPTY_PUBLISHED_CONSTANT_IVARS, :EMPTY_REPEATED_OR_WRITES,
                     :EMPTY_CONSTANT_NARROWINGS, :EMPTY_GUARD_RECORDS, :EMPTY_BOT_GUARD_CLASSES

    class << self
      def empty(environment: Environment.default, source_path: nil)
        new(environment: environment, locals: {}.freeze,
            fact_store: Analysis::FactStore.empty, source_path: source_path)
      end
    end

    def record_dynamic_origin(node, cause)
      @dynamic_origins[node] = cause
      self
    end

    # ADR-100 WD3 — records that the value introduced at `node` (a call node) is a `top` recovered from an
    # author-declared `-> void` return, keyed by the origin site (`origin`, an {Inference::VoidOrigin}). The
    # value-context check rule `static.value-use.void` consumes this table. Mirrors {#record_dynamic_origin}
    # exactly: identity-keyed advisory metadata, mutated in place on the shared table (threaded by reference
    # through `#join` / `#rebuild`), excluded from `==` / `hash`, so it never forks a flow-dedup or cache key.
    def record_void_origin(node, origin)
      @void_origins[node] = origin
      self
    end

    # Issue #653 — records that a plugin's `dynamic_return` answered the return type for `node`, i.e. that
    # `MethodDispatcher`'s plugin tier (which sits ABOVE `RbsDispatch`) is where the site's type came from.
    # `Analysis::CheckRules` consults it so `call.undefined-method` does not then read the receiver's RBS to
    # prove the same call undefined: the engine already decided the plugin outranks the signature here, and a
    # partially-declared receiver is not a closed world (ADR-5). Mirrors {#record_void_origin} exactly —
    # identity-keyed advisory metadata on a table threaded by reference through `#join` / `#rebuild`,
    # excluded from `==` / `hash`, so it never forks a flow-dedup or cache key.
    def record_plugin_typed_call(node)
      @plugin_typed_calls[node] = true
      self
    end

    # Issue #653 — whether a plugin answered the return type for `node` on this run.
    def plugin_typed_call?(node)
      @plugin_typed_calls.key?(node)
    end

    def initialize( # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- one keyword and assignment per field
      environment:, locals:,
      fact_store: Analysis::FactStore.empty,
      self_type: nil,
      ivars: EMPTY_VAR_BINDINGS,
      cvars: EMPTY_VAR_BINDINGS,
      globals: EMPTY_VAR_BINDINGS,
      discovery: DiscoveryIndex::EMPTY,
      indexed_narrowings: EMPTY_INDEXED_NARROWINGS,
      method_chain_narrowings: EMPTY_CHAIN_NARROWINGS,
      declaration_sourced: EMPTY_DECLARATION_SOURCED,
      published_constant_sourced: EMPTY_PUBLISHED_CONSTANT_SOURCED,
      source_path: nil,
      struct_fold_safe_locals: EMPTY_FOLD_SAFE,
      opaque_block_self: false,
      singleton_class_body: false,
      lexical_nesting: nil,
      dynamic_origins: {}.compare_by_identity,
      local_origins: EMPTY_ORIGINS,
      ivar_origins: EMPTY_ORIGINS,
      void_origins: {}.compare_by_identity,
      plugin_typed_calls: {}.compare_by_identity,
      optimistic_origins: {}.compare_by_identity,
      optimistic_locals: EMPTY_ORIGINS,
      optimistic_ivars: EMPTY_ORIGINS,
      repeated_or_writes: EMPTY_REPEATED_OR_WRITES,
      match_frame: nil,
      constant_narrowings: EMPTY_CONSTANT_NARROWINGS,
      guard_records: EMPTY_GUARD_RECORDS,
      bot_guard_classes: EMPTY_BOT_GUARD_CLASSES
    )
      @environment = environment
      @locals = locals
      @fact_store = fact_store
      @self_type = self_type
      @ivars = ivars
      @cvars = cvars
      @globals = globals
      @discovery = discovery
      @indexed_narrowings = indexed_narrowings
      @method_chain_narrowings = method_chain_narrowings
      @declaration_sourced = declaration_sourced
      @published_constant_sourced = published_constant_sourced
      @source_path = source_path
      @struct_fold_safe_locals = struct_fold_safe_locals
      @opaque_block_self = opaque_block_self
      @singleton_class_body = singleton_class_body
      @lexical_nesting = lexical_nesting
      @dynamic_origins = dynamic_origins
      @local_origins = local_origins
      @ivar_origins = ivar_origins
      @void_origins = void_origins
      @plugin_typed_calls = plugin_typed_calls
      @optimistic_origins = optimistic_origins
      @optimistic_locals = optimistic_locals
      @optimistic_ivars = optimistic_ivars
      @repeated_or_writes = repeated_or_writes
      @match_frame = match_frame
      @constant_narrowings = constant_narrowings
      @guard_records = guard_records
      @bot_guard_classes = bot_guard_classes
      freeze
    end

    # Issue #286 — the {Inference::OptimisticOrigin} cause attached to a call node whose result is nil-free
    # only because `RbsDispatch` reads past `%a{implicitly-returns-nil}`, or `nil` when the value's
    # nil-freeness is a property of its class. Mirrors {#dynamic_origins} / {#void_origins}: advisory
    # metadata, ignored by `==` / `hash`, and never varying a flow decision on its own.
    def record_optimistic_origin(node, cause)
      @optimistic_origins[node] = cause
      self
    end

    # Issue #1703 — this scope with private copies of the identity-keyed side tables (dynamic, void and optimistic
    # origins, plugin-typed calls), so a second walk from it — the `key?`-guarded re-walk — records into its own
    # tables and never into the ones the file's analysis reads.
    def with_isolated_side_tables
      rebuild(dynamic_origins: @dynamic_origins.dup, void_origins: @void_origins.dup,
              plugin_typed_calls: @plugin_typed_calls.dup, optimistic_origins: @optimistic_origins.dup)
    end

    def optimistic_local(name) = Inference::OptimisticOrigin.bound_cause(@optimistic_locals[name.to_sym])
    def optimistic_ivar(name) = Inference::OptimisticOrigin.bound_cause(@optimistic_ivars[name.to_sym])

    # Issue #1302 — what the value a marked local / ivar is bound to answers on a miss, as its binding recorded
    # it beside the mark, or {Inference::OptimisticOrigin::UNKNOWN_MISS}. The answer lives in the mark's own
    # table entry ({Inference::OptimisticOrigin::BoundMark}), so every transition that keeps or drops the mark
    # keeps or drops the answer with it.
    def optimistic_local_miss(name) = Inference::OptimisticOrigin.bound_miss(@optimistic_locals[name.to_sym])
    def optimistic_ivar_miss(name) = Inference::OptimisticOrigin.bound_miss(@optimistic_ivars[name.to_sym])

    # `miss` is what the bound value answers when the bet fails ({Inference::OptimisticOrigin.miss_answer}); the
    # default records none, so a read through the binding widens as an untold miss does.
    def with_optimistic_local(name, cause, miss: Inference::OptimisticOrigin::UNKNOWN_MISS)
      return self if cause.nil?

      mark = Inference::OptimisticOrigin.bound_mark(cause, miss)
      rebuild(optimistic_locals: @optimistic_locals.merge(name.to_sym => mark).freeze)
    end

    def with_optimistic_ivar(name, cause, miss: Inference::OptimisticOrigin::UNKNOWN_MISS)
      return self if cause.nil?

      mark = Inference::OptimisticOrigin.bound_mark(cause, miss)
      rebuild(optimistic_ivars: @optimistic_ivars.merge(name.to_sym => mark).freeze)
    end

    # ADR-82 WD1 — the propagated origin of the `Dynamic` value currently bound to a local / instance
    # variable, or `nil` when none is tracked. Consulted by `Inference::ProtectionScanner` when a dispatch's
    # receiver is a bare `x` / `@x` read whose own node carries no origin.
    def local_origin(name) = @local_origins[name.to_sym]
    def ivar_origin(name) = @ivar_origins[name.to_sym]

    # Records the cause of the `Dynamic` value being bound to `name`. A `nil` cause is a no-op (the common
    # case — most bindings are concrete or have no recorded origin), so callers need not pre-check.
    def with_local_origin(name, cause)
      return self if cause.nil?

      rebuild(local_origins: @local_origins.merge(name.to_sym => cause).freeze)
    end

    def with_ivar_origin(name, cause)
      return self if cause.nil?

      rebuild(ivar_origins: @ivar_origins.merge(name.to_sym => cause).freeze)
    end

    def local(name)
      @locals[name.to_sym]
    end

    def with_local(name, type)
      bind_local(name, type, keep_marks: false)
    end

    # The one body behind {#with_local} and {#with_mutated_local}, which differ only in whether the two marks a
    # write drops survive. Passing the kept sets through unchanged, rather than dropping and re-adding them, keeps
    # a mutation's rebind to the one `rebuild` a write costs.
    def bind_local(name, type, keep_marks:)
      # `rigor trace` — the moment a local enters the scope.
      Inference::FlowTracer.bind(name, type) if Inference::FlowTracer.active?
      new_locals = @locals.merge(name.to_sym => type).freeze
      new_fact_store = fact_store.invalidate_target(Analysis::FactStore::Target.local(name))
      # Rebinding `name` invalidates every "after `receiver[key] ||= default`" narrowing keyed on it — the slot at
      # `name[*]` is reachable through the old binding only, so the next read against the new binding does not
      # inherit the earlier non-nil guarantee. The same logic applies to method-chain narrowings: `x.last` after
      # `x = something_new` is a call on the new binding and any prior `is_a?`-driven narrowing keyed on
      # `(local, :x, :last)` no longer holds.
      new_indexed_narrowings = drop_indexed_narrowings_for(:local, name)
      new_chain_narrowings = drop_chain_narrowings_for(:local, name)
      # ADR-58 WD1 — rebinding a local is a flow-live touch: any prior declaration-sourced mark on `name` no
      # longer holds (the new value may carry a method-local nil). `with_declaration_sourced_local` re-establishes
      # the mark afterward when the RHS is a pure copy of a declaration-sourced ivar read; the default is to drop
      # it.
      rebuild(locals: new_locals, fact_store: new_fact_store,
              indexed_narrowings: new_indexed_narrowings,
              method_chain_narrowings: new_chain_narrowings,
              declaration_sourced: keep_marks ? @declaration_sourced : drop_local_declaration_marks(name),
              # Issue #667 — rebinding is flow-live for the published-constant mark too: the new value need
              # not be a copy of anything. `with_published_constant_mark` re-stamps afterward when the write's
              # rvalue is one.
              published_constant_sourced: drop_published_constant_sourced_for(:local, name),
              local_origins: drop_origin(@local_origins, name),
              optimistic_locals: keep_marks ? @optimistic_locals : drop_origin(@optimistic_locals, name),
              bot_guard_classes: drop_bot_guard_class(:local, name))
    end
    private :bind_local

    def with_fact(fact)
      rebuild(fact_store: fact_store.with_fact(fact))
    end

    # Slice A-engine. Returns a scope with `self_type` set to `type`, preserving locals and facts.
    # `StatementEvaluator` injects this at class-body and method-body boundaries; `ExpressionTyper` consults it
    # when typing `Prism::SelfNode` and implicit-self `Prism::CallNode` receivers.
    def with_self_type(type)
      rebuild(self_type: type)
    end

    # Issue #652 — installs the body's REAL `Module.nesting`, innermost first, as recorded at declaration
    # time by `Inference::StatementEvaluator` (`["Admin::UsersController"]` for a compact
    # `class Admin::UsersController`, `["Admin::UsersController", "Admin"]` for the nested spelling). A
    # qualified name cannot be un-flattened back into the chain that produced it, so the chain has to travel
    # with the scope; `Reflection.lexical_nesting_chain` is the single reader.
    #
    # The value is THREE-valued, and issue #716 is what the third state is for:
    #
    # - a non-empty chain — the body's real `Module.nesting`, recorded at declaration time;
    # - `[]` — recorded, and the body is written at the TOP LEVEL. Ruby's `Module.nesting` there is empty,
    #   so a top-level `def helper = Post.new` names `::Post` no matter which namespace calls it.
    #   `Reflection.resolve_constant_type` consults the top level FIRST for such a scope and only then the
    #   caller-derived rungs, instead of letting the caller's namespace answer;
    # - `nil` — NOT recorded, for a scope built outside a declaration walk (a callee body re-entered through
    #   `Scope#evaluate`, a plugin-constructed scope). The reader then peels `self_type`'s class name — a
    #   gradual answer, never a new firing.
    #
    # Collapsing `[]` into `nil` is precisely the bug #716 fixed, so a writer that has an empty chain must
    # pass it rather than skip the stamp.
    def with_lexical_nesting(chain)
      rebuild(lexical_nesting: chain)
    end

    # ADR-28 / ADR-52 slice 5a — per-file source path carried on the scope. The analyzer stamps the current file's
    # path onto the seed scope; nested rebuilds propagate it so plugin rules (`dynamic_return`'s `file_methods:`
    # gate, sigil checks) can resolve "which file does this call site belong to?" without thread-locals.
    def with_source_path(path)
      rebuild(source_path: path)
    end

    # ADR-48 Struct slice 3 — installs the per-body fold-safe-local set ({Inference::StructFoldSafety}). Set once
    # at body entry; inherited unchanged through subsequent flow transitions.
    def with_struct_fold_safe(locals)
      rebuild(struct_fold_safe_locals: locals)
    end

    # Issue #316 — marks a block body whose `self` Rigor does not model. Ruby gives a block no `self` of its
    # own: the yielding method decides, and `instance_eval` / `instance_exec` (the mechanism behind every
    # `self`-rebinding DSL — RSpec example groups, `Class.new { … }`, Rake, Sinatra) is indistinguishable from
    # `Array#each` without knowing the callee. The flag is set at every block entry that leaves `self_type`
    # unnarrowed and is inherited by every scope derived inside the block; it never leaks past the block,
    # because `eval_call` returns the caller's scope unchanged.
    def entering_opaque_block
      return self if @opaque_block_self

      rebuild(opaque_block_self: true)
    end

    # True when this scope sits inside a block whose `self` is unmodelled ({#entering_opaque_block}).
    def opaque_block_self? = @opaque_block_self

    # Issue #963 — marks the body of a `class << ...` as such. Inside it `self` is the SINGLETON class, which
    # Rigor models with the same `Singleton[X]` carrier a `class X` body gets, so the carrier alone cannot say
    # which of the two a scope came from. The distinction decides what `define_method` does: in a `class << self`
    # body it defines a CLASS method (`self` there is the singleton class), while in every other body reached
    # with a `Singleton[X]` self — a `class X` body, `def self.x`, a `def` inside `class << self` — `self` is the
    # class object and the same call defines an INSTANCE method.
    #
    # The mark is stamped at singleton-class-body entry and inherited by every scope derived inside it, blocks
    # included; a `def` body starts from a fresh scope and therefore clears it by construction, which is exactly
    # the boundary the distinction needs. A meta-class body (`Class.new do ... end`) clears it explicitly: that
    # block is a class body of its own, whatever encloses it.
    def with_singleton_class_body(flag)
      return self if @singleton_class_body == flag

      rebuild(singleton_class_body: flag)
    end

    # True when this scope IS a `class << ...` body (not merely inside one lexically — a `def` reached from it
    # answers false).
    def singleton_class_body? = @singleton_class_body

    # True when `name`'s `Struct` member reads are fold-safe in this body (the local is provably never mutated /
    # aliased / escaped).
    def struct_fold_safe?(name)
      @struct_fold_safe_locals.include?(name.to_sym)
    end

    # ADR-53 Track A — swaps the whole discovery index in one transition. The sole seeding path; the per-table
    # writers it replaced are derived off-`Scope` through `scope.discovery.with(table_name: table)`.
    def with_discovery(index)
      rebuild(discovery: index)
    end

    # Slice 7 phase 1 — instance/class/global variable bindings. `ivar(name)` / `cvar(name)` / `global(name)`
    # return the type currently bound for the named variable, or `nil` when the variable has not been written in
    # the analyzed slice of the program. The first cut tracks bindings only within a single method body (each
    # `def` enters with a fresh binding map), so reads in other methods of the same class fall through to
    # `Dynamic[Top]`. Cross-method ivar/cvar inference is a follow-up slice.
    def ivar(name)
      @ivars[name.to_sym]
    end

    def cvar(name)
      @cvars[name.to_sym]
    end

    def global(name)
      @globals[name.to_sym]
    end

    def with_ivar(name, type)
      bind_ivar(name, type, @guard_records)
    end

    # The one body behind {#with_ivar} and {#with_guarded_ivar}, which differ only in the guard records they leave.
    def bind_ivar(name, type, guard_records)
      new_indexed_narrowings = drop_indexed_narrowings_for(:ivar, name)
      new_chain_narrowings = drop_chain_narrowings_for(:ivar, name)
      # ADR-58 WD1 — a method-local ivar write or narrowing is flow-live: drop any declaration-sourced mark so
      # subsequent reads of `@name` observe flow-live provenance and fire as before. The seed path uses
      # `seed_declaration_sourced_ivar` to (re-)establish the mark.
      rebuild(ivars: @ivars.merge(name.to_sym => type).freeze,
              indexed_narrowings: new_indexed_narrowings,
              method_chain_narrowings: new_chain_narrowings,
              declaration_sourced: drop_declaration_sourced_for(:ivar, name),
              published_constant_sourced: drop_published_constant_sourced_for(:ivar, name),
              ivar_origins: drop_origin(@ivar_origins, name),
              optimistic_ivars: drop_origin(@optimistic_ivars, name),
              guard_records: guard_records,
              bot_guard_classes: drop_bot_guard_class(:ivar, name))
    end
    private :bind_ivar

    # ADR-58 WD1 — used by the method-entry seed to mark an ivar whose only provenance is the class-ivar index.
    # Unlike `with_ivar` this binds the type AND records the declaration-sourced mark in one transition.
    def seed_declaration_sourced_ivar(name, type)
      rebuild(ivars: @ivars.merge(name.to_sym => type).freeze,
              declaration_sourced: add_declaration_sourced(:ivar, name))
    end

    # ADR-58 WD1 — a local assignment `r = @right` whose RHS is a pure read of a declaration-sourced ivar inherits
    # the mark, so the survey's exact rotation/traversal shape (`r = @right; r.key`) does not fire. Binds the type
    # and stamps the local's mark in one transition (the plain `with_local` would have dropped it).
    def with_declaration_sourced_local(name, type)
      written = with_local(name, type)
      written.with_local_declaration_mark(name)
    end

    # ADR-58 WD1 — re-stamp the local mark on a scope produced by `with_local` (which always drops it). Public so
    # the sibling `with_declaration_sourced_local` can call it across the new post-write receiver without reaching
    # into a private method.
    def with_local_declaration_mark(name)
      rebuild(declaration_sourced: add_declaration_sourced(:local, name))
    end

    # Issue #1287 — rebinds `name` for an in-place mutation of the object it already holds: a mutator's widening
    # (`r << x`), a content floor after a closure or callee mutated it, an element or member write through it. The
    # binding still names the same object, so this is not a flow-live write, and the marks `with_local` drops stay:
    # ADR-58's declaration-sourced mark and issue #286's optimistic nil-freeness mark, with the miss answer issue
    # #1302 records in it. A source-level write keeps going through `with_local`, which drops both.
    #
    # Two other per-local tables are deliberately still dropped. An ADR-82 `local_origins` cause explains the
    # `Dynamic` the ASSIGNMENT bound, and a floor's `Dynamic[top]` has a different cause. Issue #667's
    # published-constant mark can never be live here: only a frozen scalar publishes, and a frozen value is not
    # mutated in place.
    def with_mutated_local(name, type)
      bind_local(name, type, keep_marks: true)
    end

    # Issue #667 — record that `name` is currently bound to a value copied out of a foreign published
    # constant. Always applied AFTER the `with_local` / `with_ivar` that binds the value (both drop the mark
    # unconditionally), exactly as {#with_local_declaration_mark} is.
    def with_published_constant_mark(kind, name)
      rebuild(published_constant_sourced: add_published_constant_sourced(kind, name))
    end

    # Issue #667 — true when `(kind, name)`'s current binding is a copy of a constant the project published
    # and this file does not declare. Asked through
    # {Analysis::CheckRules::PublishedConstantGuard}, never directly from a rule.
    def published_constant_sourced?(kind, name)
      return false if @published_constant_sourced.empty?

      @published_constant_sourced.include?([kind.to_sym, name.to_sym])
    end

    # ADR-58 WD1 — true when `(kind, name)`'s binding optionality is purely declaration-sourced (no flow-live
    # write/narrowing has touched it).
    def declaration_sourced?(kind, name)
      return false if @declaration_sourced.empty?

      @declaration_sourced.include?([kind.to_sym, name.to_sym])
    end

    # ADR-67 WD6b — stamp the "inferred, not declared" provenance mark on a parameter local seeded from the
    # call-site parameter-inference table ({Inference::ParameterInferenceCollector}). Rides the ADR-58 WD1
    # declaration-sourced side-mark machinery under a distinct `:inferred_param` kind (never a carrier field,
    # so the displayed type is unchanged) so the negative in-body rules can decline on a receiver / argument
    # whose type is an open-call-site *lower bound* — firing against a lower bound is a false positive by
    # construction (the ADR-67 WD1 reasoning at the parameter boundary, carried one hop into the body). The
    # distinct kind keeps the inferred-param sites separable from ADR-58's ivar-copy `:local` mark, which a
    # later un-guarding slice (WD6b) needs — and the two kinds behave OPPOSITELY on both axes: `:local` is
    # dropped by `with_local` and intersected by `join`, while `:inferred_param` is sticky across `with_local`
    # and unioned by `join`. See {#without_inferred_param_mark} below for the clearing contract, and
    # `docs/internal-spec/inference-engine.md` § "Declaration-sourced provenance mark (ADR-58)" for the
    # normative statement of both.
    def with_inferred_param_mark(name)
      rebuild(declaration_sourced: add_declaration_sourced(:inferred_param, name))
    end

    # ADR-67 WD6b — explicitly clear the inferred-parameter taint on `name`. The mark is deliberately STICKY:
    # `with_local` (used by both narrowing and reassignment) does NOT drop it, so it survives the narrowing /
    # join transitions between a lower-bound value's definition and its use (`v = param[i]-1; if 0<=v and v<n`
    # — the `and` narrows `v` between the two comparisons). It is cleared only at a genuine source-level local
    # write whose RHS does not derive from an inferred parameter ({StatementEvaluator#eval_local_write}), so a
    # local rebound to an independent value stops being treated as a lower bound. Over-retention (a mark that
    # outlives a rebind the write-path did not catch) only ever suppresses a diagnostic — the FP-safe
    # direction — so stickiness is the conservative choice. Zero-alloc when no mark is present.
    def without_inferred_param_mark(name)
      dropped = drop_declaration_sourced_for(:inferred_param, name)
      dropped.equal?(@declaration_sourced) ? self : rebuild(declaration_sourced: dropped)
    end

    # ADR-67 WD6b — true when `name`'s local binding is a pristine inferred parameter (the call-site union
    # seeded at method entry, untouched by a flow-live write). The guard predicate the negative in-body rules
    # consult.
    def inferred_param?(name)
      @declaration_sourced.include?([:inferred_param, name.to_sym])
    end

    def with_cvar(name, type)
      rebuild(cvars: @cvars.merge(name.to_sym => type).freeze)
    end

    # Issue #1362 — a write or narrowing of a global is flow-live, so it drops the ADR-58 `:global` mark
    # {#seed_declaration_sourced_global} stamped on the program-global seed.
    #
    # Issue #1429 — `$stdout` and `$>` are one variable, so a write to either also restores a guard's narrowing of the
    # other ({#forget_guard_narrowing_of}).
    def with_global(name, type)
      name = name.to_sym
      written = rebuild(globals: @globals.merge(name => type).freeze,
                        declaration_sourced: drop_declaration_sourced_for(:global, name),
                        guard_records: drop_guard_record(:global, name),
                        bot_guard_classes: drop_bot_guard_class(:global, name))
      alias_name = STDOUT_ALIASES[name]
      alias_name ? written.forget_guard_narrowing_of(:global, alias_name) : written
    end

    STDOUT_ALIASES = { :$stdout => :$>, :$> => :$stdout }.freeze
    private_constant :STDOUT_ALIASES

    # Issue #1429 — {#forget_guard_narrowings} for the one name `[kind, name]`.
    def forget_guard_narrowing_of(kind, name)
      key = [kind, name]
      pre_guard = @guard_records[key]
      return self if pre_guard.nil?

      if kind == :global
        current = @globals[name]
        globals = current ? @globals.merge(name => Type::Combinator.union(pre_guard, current)).freeze : @globals
        rebuild(globals: globals, guard_records: @guard_records.except(key).freeze)
      else
        current = @constant_narrowings[name]
        constants = if current
                      @constant_narrowings.merge(name => Type::Combinator.union(pre_guard, current)).freeze
                    else
                      @constant_narrowings
                    end
        rebuild(constant_narrowings: constants, guard_records: @guard_records.except(key).freeze)
      end
    end

    # Issue #1429 — binds the global `name` to `type` on a guard's edge, recording `pre_guard`, the binding the guard
    # narrowed, unless an earlier guard already recorded one ({EMPTY_GUARD_RECORDS}). `record: false` is the
    # frame-local specials' form, which binds without a record: their own machinery forgets them.
    def with_guarded_global(name, type, pre_guard, record: true)
      name = name.to_sym
      records = record ? add_guard_record([:global, name].freeze, pre_guard) : drop_guard_record(:global, name)
      rebuild(globals: @globals.merge(name => type).freeze,
              declaration_sourced: drop_declaration_sourced_for(:global, name),
              guard_records: records,
              bot_guard_classes: drop_bot_guard_class(:global, name))
    end

    # Issue #1446 — binds the instance variable `name` to `type` on a class guard's edge, recording `pre_guard` as
    # {#with_guarded_global} does. The truthiness, `nil?`, `&.` and `respond_to?` guards narrow an instance variable
    # through {#with_ivar} and record nothing.
    def with_guarded_ivar(name, type, pre_guard)
      name = name.to_sym
      bind_ivar(name, type, add_guard_record([:ivar, name].freeze, pre_guard))
    end

    # Issue #1446 — this scope with no guard record for the instance variable `name`: what a write to it leaves.
    # {#with_ivar} keeps the record, since a narrowing binds through it too.
    def without_ivar_guard(name)
      records = drop_guard_record(:ivar, name.to_sym)
      records.equal?(@guard_records) ? self : rebuild(guard_records: records)
    end

    # Issue #1446 — true when a class guard's narrowing of the instance variable `name` is live.
    def guard_narrowed_ivar?(name)
      !@guard_records.empty? && @guard_records.key?([:ivar, name.to_sym])
    end

    # Issue #1429 — the type a guard narrowed the constant reference `key` to, or nil.
    def constant_narrowing(key)
      return nil if @constant_narrowings.empty?

      @constant_narrowings[key]
    end

    # Issue #1429 — the constant reference `key` read as `type` on a guard's edge, recording `pre_guard` as
    # {#with_guarded_global} does.
    def with_constant_narrowing(key, type, pre_guard)
      rebuild(constant_narrowings: @constant_narrowings.merge(key => type).freeze,
              guard_records: add_guard_record([:constant, key].freeze, pre_guard),
              bot_guard_classes: drop_bot_guard_class(:constant, key))
    end

    # Issue #1446 — this scope with `class_names` recorded as the classes a class guard narrowed the receiver `[kind,
    # name]` to, where the guard left it `bot` ({EMPTY_BOT_GUARD_CLASSES}). Call it after the narrowing, which drops
    # any earlier entry.
    def with_bot_guard_classes(kind, name, class_names)
      key = [kind, kind == :constant ? name : name.to_sym].freeze
      rebuild(bot_guard_classes: @bot_guard_classes.merge(key => class_names.dup.freeze).freeze)
    end

    # Issue #1446 — the classes a class guard narrowed the `bot` receiver `[kind, name]` to, or nil.
    def bot_guard_classes_for(kind, name)
      return nil if @bot_guard_classes.empty?

      @bot_guard_classes[[kind, name]]
    end

    # Issue #1429 — every constant reference whose last segment is `name` with no narrowing: what a write to a constant
    # named `name` leaves, since `Foo::BAR` and `BAR` may name the one it wrote.
    def without_constant_narrowings_named(name)
      keys = @constant_narrowings.keys.select { |key| key.split("::").last == name }
      return self if keys.empty?

      records = @guard_records.reject { |(kind, key), _| kind == :constant && keys.include?(key) }
      classes = @bot_guard_classes.except(*keys.map { |key| [:constant, key] }).freeze
      rebuild(constant_narrowings: @constant_narrowings.except(*keys).freeze, guard_records: records.freeze,
              bot_guard_classes: classes)
    end

    # Issue #1429 — the constant reference `key` with no narrowing.
    def without_constant_narrowing(key)
      return self unless @constant_narrowings.key?(key)

      rebuild(constant_narrowings: @constant_narrowings.except(key).freeze,
              guard_records: @guard_records.except([:constant, key]).freeze,
              bot_guard_classes: drop_bot_guard_class(:constant, key))
    end

    # True when a guard's narrowing of a global, constant or instance variable is live, the state
    # {#forget_guard_narrowings} drops and so the gate on every scan that decides whether to.
    def guard_narrowed?
      !@guard_records.empty?
    end

    # Issue #1429 — this scope past code that may rebind a global or a constant: each one a guard narrowed reads
    # the union of its narrowed type and the binding the guard narrowed, and no record is left. The union, not the
    # pre-guard binding alone, because the code may leave the value as it was: `$stdout.is_a?(StringIO)`, then a
    # helper, reads `IO | StringIO`, which keeps `$stdout.string` quiet as the guard intended.
    #
    # Issue #1446 — an instance variable a class guard narrowed is restored the same way.
    def forget_guard_narrowings
      return self if @guard_records.empty?

      tables = { global: @globals, constant: @constant_narrowings, ivar: @ivars }
      @guard_records.each do |(kind, name), pre_guard|
        table = tables.fetch(kind)
        current = table[name]
        tables[kind] = table.merge(name => Type::Combinator.union(pre_guard, current)) if current
      end
      globals, constants, ivars = tables.values_at(:global, :constant, :ivar).map { |t| t.frozen? ? t : t.freeze }
      rebuild(globals: globals, constant_narrowings: constants, ivars: ivars, guard_records: EMPTY_GUARD_RECORDS)
    end

    # Issue #1362 (ADR-58 parity, ADR-117 Decision point 2) — used by the method-entry and top-level seeds to bind a
    # global Ruby's own signatures declare to its declared type joined with the file's writes, and to record that the
    # binding is still that seed. The declared members are real type information but not diagnostic fuel
    # ({Analysis::CheckRules::DeclarationSourcedGuard}); a write or narrowing drops the mark ({#with_global}).
    def seed_declaration_sourced_global(name, type)
      rebuild(globals: @globals.merge(name.to_sym => type).freeze,
              declaration_sourced: add_declaration_sourced(:global, name))
    end

    # Issue #1362 — a local written from a read of a marked global (`sep = $/`) carries ADR-58's `:local` mark, and
    # this records the globals it may copy, so a consumer can compare against the file's writes to them
    # ({#declaration_sourced_global_copies}). Applied after {#with_declaration_sourced_local}; the local's next
    # rebinding drops both ({#bind_local}), and a join of two copies keeps both branches' globals.
    def with_global_copy_marks(name, globals)
      name = name.to_sym
      added = globals.map { |global| [:global_copy, name, global.to_sym].freeze }
                     .reject { |ref| @declaration_sourced.include?(ref) }
      return self if added.empty?

      rebuild(declaration_sourced: @declaration_sourced.dup.merge(added).freeze)
    end

    # Issue #1362 — this scope with the local `name`'s ADR-58 mark and copy record dropped and its binding kept: a
    # retried pass that re-enters with a binding the accumulated one accepts, but from another source.
    def without_local_declaration_marks(name)
      dropped = drop_local_declaration_marks(name)
      dropped.equal?(@declaration_sourced) ? self : rebuild(declaration_sourced: dropped)
    end

    # The globals the local `name` is a marked copy of ({#with_global_copy_marks}), empty for a local that copies
    # no marked global.
    def declaration_sourced_global_copies(name)
      return EMPTY_GLOBAL_COPIES unless declaration_sourced?(:local, name)

      name = name.to_sym
      @declaration_sourced.filter_map { |ref| ref[2] if ref[0] == :global_copy && ref[1] == name }
    end
    EMPTY_GLOBAL_COPIES = [].freeze
    private_constant :EMPTY_GLOBAL_COPIES

    # Mark `nodes`, index `||=` sites, as ones whose slot an earlier run of a repeating block body may have
    # filled ({EMPTY_REPEATED_OR_WRITES}).
    def with_repeated_or_writes(nodes)
      return self if nodes.all? { |node| @repeated_or_writes.key?(node) }

      marked = @repeated_or_writes.dup
      nodes.each { |node| marked[node] = true }
      rebuild(repeated_or_writes: marked.freeze)
    end

    # True when {#with_repeated_or_writes} marked the index `||=` node `node` (by identity).
    def repeated_or_write?(node)
      return false if @repeated_or_writes.empty?

      @repeated_or_writes.key?(node)
    end

    # Regex match-data globals (`$~`, `$&`, `$1..$9`, the pre/post-match and last-paren back-references). Narrowed
    # on a successful-`=~` / `case`-`when` match edge (see `Narrowing#regex_match_predicate_scopes`). They live in
    # the method frame's special-variable slot, which the method's blocks and closures share (issue #1358), so a
    # later call that may run a match in this frame — a match-capable call, a block that may match, a call once
    # the frame has made a closure that may — rebinds every one of them, and `eval_call` forgets the narrowed
    # facts here. Always safe — only drops facts, so a subsequent read falls back to the default `String | nil`.
    # Program-level `$GLOBAL = ...` seeds use other names and are untouched.
    MATCH_DATA_GLOBALS = %i[$~ $& $` $' $+ $1 $2 $3 $4 $5 $6 $7 $8 $9].freeze
    private_constant :MATCH_DATA_GLOBALS

    def forget_match_globals
      return self unless match_globals_bound?

      rebuild(globals: @globals.except(*MATCH_DATA_GLOBALS).freeze)
    end

    # Issue #1361 — this scope with every bound match-data global rebound to `Dynamic[top]`, and an unbound one left
    # unbound: the view a `define_method` / `define_singleton_method` body enters with
    # ({Inference::FreshFrameBlocks.entry}). The body reads the defining frame's slot whenever the method is called,
    # which the narrowing where it is written neither proves nor refutes, so it is neither narrowed nor flagged.
    def untyped_match_globals
      return self unless match_globals_bound?

      untyped = Type::Combinator.untyped
      rebound = MATCH_DATA_GLOBALS.each_with_object({}) { |name, acc| acc[name] = untyped if @globals.key?(name) }
      rebuild(globals: @globals.merge(rebound).freeze)
    end

    # True when any match-data global holds a binding, which a match edge or {#untyped_match_globals} makes: the only
    # state {#forget_match_globals} can drop, and so the gate on every scan that decides whether to.
    def match_globals_bound?
      !@globals.empty? && MATCH_DATA_GLOBALS.any? { |name| @globals.key?(name) }
    end

    # Issue #1359 — the last line read, `$_`, lives in the same frame slot as the match globals, and so on the same
    # terms: a `gets`-family call, a write, or a block or closure of the frame that may run either rebinds it
    # ({Inference::LastLine}). It is bound only where a condition on a reader narrows it, or where code writes it.
    LAST_LINE = :$_
    private_constant :LAST_LINE

    def forget_last_line
      return self unless last_line_bound?

      rebuild(globals: @globals.except(LAST_LINE).freeze)
    end

    # The `$_` half of {#untyped_match_globals}: a bound `$_` rebound to `Dynamic[top]`, an unbound one left alone.
    def untyped_last_line
      return self unless last_line_bound?

      rebuild(globals: @globals.merge(LAST_LINE => Type::Combinator.untyped).freeze)
    end

    # The gate on every scan that decides whether to forget `$_`, as {#match_globals_bound?} is for the match globals.
    def last_line_bound?
      !@globals.empty? && @globals.key?(LAST_LINE)
    end

    # Issue #1360 — the exception being rescued, `$!`, and its backtrace, `$@`. Ruby finds them through the nearest
    # rescue frame of the running execution context, not through the method frame, so they are bound only inside a
    # `rescue` clause or a rescue modifier's fallback and read their earlier binding again once it exits
    # ({Inference::ErrorInfo}). `$?`, the status of the last child process, is thread-local, and is bound after a
    # subprocess call ({Inference::LastStatus}).
    ERROR_INFO_GLOBALS = %i[$! $@].freeze
    LAST_STATUS_GLOBALS = %i[$?].freeze
    private_constant :ERROR_INFO_GLOBALS, :LAST_STATUS_GLOBALS

    # This scope with `$!` and `$@` unbound: the view of a body that runs outside the rescue clause it is written in.
    def forget_error_info = forget_globals(ERROR_INFO_GLOBALS)

    # This scope with a bound `$!` or `$@` rebound to `Dynamic[top]`, and an unbound one left unbound, as
    # {#untyped_match_globals} gives a `define_method` body.
    def untyped_error_info = untyped_globals(ERROR_INFO_GLOBALS)

    # This scope with `$?` unbound: the view of a body that may run on another thread.
    def forget_last_status = forget_globals(LAST_STATUS_GLOBALS)

    # The `$?` half of {#untyped_error_info}.
    def untyped_last_status = untyped_globals(LAST_STATUS_GLOBALS)

    def forget_globals(names)
      return self if @globals.empty? || names.none? { |name| @globals.key?(name) }

      rebuild(globals: @globals.except(*names).freeze)
    end

    def untyped_globals(names)
      return self if @globals.empty? || names.none? { |name| @globals.key?(name) }

      untyped = Type::Combinator.untyped
      rebound = names.each_with_object({}) { |name, acc| acc[name] = untyped if @globals.key?(name) }
      rebuild(globals: @globals.merge(rebound).freeze)
    end
    private :forget_globals, :untyped_globals

    # Issue #1358 — stamps the frame `body` runs in ({Inference::MatchRebinding::Frame}) on a method, class or
    # file body's entry scope; a method passes its `parameters` too, whose defaults run in the same frame. Every
    # scope derived from it, a block's included, runs in that frame.
    def with_match_frame(body, parameters = nil)
      rebuild(match_frame: Inference::MatchRebinding::Frame.new(body, parameters))
    end

    # True when this scope's frame makes a closure that may rebind its match globals whenever it is invoked
    # ({Inference::MatchRebinding.matching_closure?}). False where no body stamped a frame.
    def match_rebinding_closure?
      !@match_frame.nil? && @match_frame.matching_closure?(self)
    end

    # True when this scope's frame makes a closure that may set its `$_` whenever it is invoked
    # ({Inference::LastLine.closure?}). False where no body stamped a frame.
    def last_line_closure?
      !@match_frame.nil? && @match_frame.last_line_closure?(self)
    end

    # Slice 7 phase 2 — class-level ivar accumulator. Keyed by the qualified class name (e.g. `"Rigor::Scope"`);
    # the value is a `Hash[Symbol, Type::t]` of every ivar that appears as a write target inside any def body of
    # that class. `StatementEvaluator#build_method_entry_scope` seeds the method body's `ivars` map from this
    # table so a `def get; @x; end` reads the type written in a sibling `def init; @x = 1; end`.
    #
    # `ScopeIndexer` populates the table once at index time through a separate pre-pass over the program. The map
    # is frozen and shared by structural reference across every derived scope.
    def class_ivars_for(class_name)
      return EMPTY_VAR_BINDINGS if class_name.nil?

      @discovery.class_ivars[class_name.to_s] || EMPTY_VAR_BINDINGS
    end

    # Slice 7 phase 6 — class-level cvar accumulator (same shape as `class_ivars` but populated from
    # `Prism::ClassVariableWriteNode` writes, and seeded on BOTH instance and singleton method bodies because Ruby
    # cvars are visible from each).
    def class_cvars_for(class_name)
      return EMPTY_VAR_BINDINGS if class_name.nil?

      @discovery.class_cvars[class_name.to_s] || EMPTY_VAR_BINDINGS
    end

    # Slice 7 phase 12 — in-source method discovery. Maps a qualified class name to a `Hash[Symbol, Symbol]` of
    # `method_name => :instance | :singleton`. Populated by `ScopeIndexer` from every `Prism::DefNode` and
    # recognised `define_method` invocation inside class/module bodies. The `rigor check` undefined-method and
    # wrong-arity rules consult this map to suppress diagnostics for methods the user has defined dynamically,
    # even when no RBS sig describes them.
    # A name defined on both sides of one class records {DiscoveryIndex::METHOD_KIND_BOTH} and matches either kind.
    def discovered_method?(class_name, method_name, kind)
      table = @discovery.discovered_methods[class_name.to_s]
      return false unless table

      recorded = table[method_name.to_sym]
      recorded == kind || recorded == DiscoveryIndex::METHOD_KIND_BOTH
    end

    # ADR-34 § "Decision" — predicate identifying a toplevel-shaped scope (no enclosing `class` / `module` body).
    # True at the top of a file AND inside a top-level `def` body (since toplevel defs leave `self_type` nil per
    # the existing scope-construction contract — the same nil-`self_type` signal ADR-24's self-call return
    # adoption historically keyed on before ADR-57 opened the gate unconditionally). Used by
    # `CheckRules#unresolved_toplevel_diagnostic` to gate the `call.unresolved-toplevel` rule so it fires only
    # outside class / module bodies, where Rails-DSL metaprogramming leniency (ADR-24 WD3 → WD4) does not apply.
    def toplevel?
      @self_type.nil?
    end

    # ADR-119 WD1 — the RAW slot of the def tables for `class_name` and `method_name`: the instance side by default,
    # the singleton side for `kind: :singleton`. The slot is a live `Prism::DefNode` or a {Inference::DefHandle}
    # (ADR-85 WD3), returned as stored: no dependency recording and no handle resolution. ADR-119 C1d/C2 decide how
    # a contested slot answers here. Callers that need a node go through {#user_def_for} or {#singleton_def_for}.
    # The `same_slot` census reads of this slot stay justified: certainty reaches them through the declaration
    # signature the producer fingerprints (C1d-a), not through this accessor.
    def def_node_slot(class_name, method_name, kind = :instance)
      table = kind == :singleton ? discovered_singleton_def_nodes : discovered_def_nodes
      per_class = table[class_name]
      per_class && per_class[method_name]
    end

    # v0.0.2 #5 — per-class table mapping `method_name (Symbol) → Prism::DefNode`. Populated by `ScopeIndexer`
    # alongside `discovered_methods` for instance-side defs only (singleton-side and `define_method`-introduced
    # methods do not contribute a static body the engine can re-type). Consumed by `ExpressionTyper` to do
    # inter-procedural return-type inference when the receiver class is user-defined and has no RBS sig.
    def user_def_for(class_name, method_name)
      table = @discovery.discovered_def_nodes[class_name.to_s]
      # ADR-85 WD3 — the value is either a live `Prism::DefNode` (cold / re-walked file) or a `DefHandle`
      # (unchanged file, bundle-rebuilt index). Dependency recording keys on the table's PRESENCE (both are
      # truthy), so it is sound regardless of resolution; only the returned node is resolved lazily.
      entry = table && table[method_name.to_sym]
      record_cross_file_method(class_name, method_name, entry) if Analysis::DependencyRecorder.active?
      Inference::DefNodeResolver.resolve(entry)
    end

    # Module-singleton call resolution (ADR-57 follow-up) — companion of {#user_def_for} for SINGLETON-side defs
    # (`def self.x`, `def Foo.x`, `class << self` bodies, and `module_function` defs). Returns the
    # `Prism::DefNode` for `class_name.method_name` invoked on the module/class constant itself, or nil. The
    # `discovered_def_nodes` table is deliberately instance-side only (its ancestor walk binds `self` as
    # `Nominal`), so singleton bodies live in a parallel table the `ScopeIndexer` populates alongside it. Records
    # the same cross-file dependency edge as the instance path (ADR-46).
    def singleton_def_for(class_name, method_name)
      table = @discovery.discovered_singleton_def_nodes[class_name.to_s]
      entry = table && table[method_name.to_sym] # live node or DefHandle (ADR-85 WD3)
      record_cross_file_method(class_name, method_name, entry, singleton: true) if Analysis::DependencyRecorder.active?
      Inference::DefNodeResolver.resolve(entry)
    end

    # ADR-46 slice 1 — note the cross-file dependency this resolution creates: the file defining
    # `class_name#method_name` (the consumer's analysis reads its body via `infer_user_method_return`), or, when
    # unresolved, a negative edge so a later definition re-checks the consumer. Gated on the recorder being
    # active — no-op on a normal run. `singleton:` selects the singleton-side source table + a `"Class.method"`
    # symbol key (vs the instance `"Class#method"`), so a class/singleton-method body edit produces a changed
    # symbol pair and scopes to the method's call sites the same way an instance-method edit does — the source
    # site is read from `discovered_singleton_def_sources`, the mirror the ScopeIndexer now records (ADR-46
    # slice 4 singleton extension). Both keys share the format `Runner#symbol_fingerprints` emits.
    def record_cross_file_method(class_name, method_name, node, singleton: false)
      symbol = "#{class_name}#{singleton ? '.' : '#'}#{method_name}"
      if node
        # ADR-46 slice 4 — pass the symbol so the recorder tracks this as a method-call (symbol-granularity) edge
        # rather than a file-level edge.
        source_table = singleton ? @discovery.discovered_singleton_def_sources : @discovery.discovered_def_sources
        Analysis::DependencyRecorder.read_site(source_table.dig(class_name.to_s, method_name.to_sym), symbol)
      else
        Analysis::DependencyRecorder.read_missing(:method, symbol)
      end
    end
    private :record_cross_file_method

    # v0.0.3 A — top-level def lookup for implicit-self calls. Returns the `Prism::DefNode` for a top-level (or
    # DSL-block-nested, outside any class body) `def <method_name>` in the file, or nil. The sentinel key is owned
    # by `Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY`; consumers should treat its presence as an opaque
    # implementation detail and go through this accessor.
    def top_level_def_for(method_name)
      table = @discovery.discovered_def_nodes[Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY]
      entry = table && table[method_name.to_sym] # live node or DefHandle (ADR-85 WD3)
      record_cross_file_toplevel(method_name, entry) if Analysis::DependencyRecorder.active?
      Inference::DefNodeResolver.resolve(entry)
    end

    # Issue #316 — the CONFIDENCE-GATED companion of {#top_level_def_for}, and the only accessor the type
    # inference may bind through. {#top_level_def_for} stays unrestricted because it also serves the
    # *suppression* side (`call.unresolved-toplevel`, `call.undefined-method`): a name the project defines at
    # the top level must never be reported as unresolved, whatever this gate decides.
    #
    # Returns nil — decline to bind, stay silent — when BOTH hold:
    #
    # 1. The call site sits inside a block whose `self` is unmodelled ({#opaque_block_self?}) and no narrowed
    #    `self_type` says otherwise. A top-level `def` is a private method on `Object`, so it is *callable*
    #    from any `self`; what the analyzer cannot see is whether the block's real `self` gained a PUBLIC
    #    same-named method by `include` / `extend`, which wins the MRO over the private `Object` def. RSpec's
    #    `output` / `include` / `match` matchers against a project's own `def output` are exactly this.
    # 2. The `def` lives in a DIFFERENT file from the call site. Collocation is the evidence that the two
    #    belong to one lexical structure — the `RSpec.describe do; def helper; end; it { helper } end` case
    #    v0.0.3 A and #319 deliberately serve. Cross-file, the two share only a name.
    #
    # Both conditions are required, so a top-level helper called from genuine top-level code keeps resolving
    # (cross-file included), and a helper defined beside its DSL-block call site keeps resolving too. When the
    # project pre-pass recorded no source for the name, the file test cannot be answered and the historical
    # bind is kept.
    def bindable_top_level_def_for(method_name)
      node = top_level_def_for(method_name)
      return node if node.nil?
      return node unless @opaque_block_self && @self_type.nil?

      same_file_top_level_def?(method_name) ? node : nil
    end

    # ADR-119 WD1 errata, deliberately unchanged: this compares the recorded site's FILE with the call's file, and
    # which file a def sits in does not depend on whether it executes. The `<toplevel>` slots are contested
    # truthfully (ADR-119 C1d-a) but unread until C2 makes the top-level reader decline on them.
    def same_file_top_level_def?(method_name)
      key = Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY
      site = discovered_def_sources.dig(key, method_name.to_sym)
      return true if site.nil? || @source_path.nil?

      File.absolute_path(site.sub(/:\d+\z/, "")) == File.absolute_path(@source_path)
    end
    private :same_file_top_level_def?

    # ADR-46 slice 3 — a top-level (`def helper` outside any class) call has NO class ancestry to walk, so unlike
    # {#user_def_for} a miss here records no positive ancestry edge that would re-check the consumer when the
    # method later appears. Record the cross-file edge explicitly: the file defining the top-level method
    # (symbol-granularity, so a body / removal edit re-checks the caller), or, on a miss, a negative `toplevel:`
    # edge so a later top-level definition re-checks this consumer (the `call.unresolved-toplevel`
    # stale-diagnostic gap).
    def record_cross_file_toplevel(method_name, node)
      key = Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY
      if node
        Analysis::DependencyRecorder.read_site(
          @discovery.discovered_def_sources.dig(key, method_name.to_sym),
          "#{key}##{method_name}"
        )
      else
        Analysis::DependencyRecorder.read_missing(:toplevel, method_name)
      end
    end
    private :record_cross_file_toplevel

    # Companion to {#user_def_for}: returns the `"path:line"` where the project defines `class_name#method_name`
    # (instance-side), or nil. Populated only by the cross-file project pre-pass
    # ({Inference::ScopeIndexer.discovered_def_index_for_paths}) — a `Prism::Location` hides its source file, so
    # the site is recorded at scan time. `CheckRules#undefined_method_diagnostic` consults this to name the
    # defining file when a project monkey-patch on a core/stdlib/gem class is called cross-file, so the diagnostic
    # can point at `pre_eval:` (ADR-17) instead of reading as a bare unresolved call.
    def user_def_site_for(class_name, method_name)
      table = @discovery.discovered_def_sources[class_name.to_s]
      site = table && table[method_name.to_sym]
      # ADR-88 WD3 — record the SAME instance-side cross-file method edge {#user_def_for} records at :378, so a
      # move / body-edit of `class_name#method_name`'s definition re-checks the consumer that named the
      # defining file. `CheckRules#undefined_method_diagnostic` reads this to set `project_definition_site`
      # (`"path:line"`) on a `call.undefined-method` for a project monkey-patch; without the edge, a line-shift
      # in the defining file left the cached diagnostic pointing at a stale line (the ADR-46 symbol-granularity
      # closure never re-checked the caller). Recording keys on the source-entry PRESENCE (truthy `site`),
      # sound whether or not the caller also went through {#user_def_for}.
      record_cross_file_method(class_name, method_name, site) if Analysis::DependencyRecorder.active?
      site
    end

    # Issue #735 — the singleton-side mirror of {#user_def_site_for}: the `"path:line"` where the project
    # defines `class_name.method_name`, or nil. Records the same cross-file edge, keyed `"Class.method"`.
    def user_singleton_def_site_for(class_name, method_name)
      table = @discovery.discovered_singleton_def_sources[class_name.to_s]
      site = table && table[method_name.to_sym]
      record_cross_file_method(class_name, method_name, site, singleton: true) if Analysis::DependencyRecorder.active?
      site
    end

    # Issue #1097 — whether `class_name`'s own singleton `def method_name` has RUN by the time `call_node`
    # executes. Such a def precedes every `extend` in the singleton ancestry, so once it exists it owns the
    # call — but `sig { ... }` written BEFORE `def self.sig` in the same body still resolves through the
    # already-extended module, because `def` takes effect at execution. The site table stores
    # `"path:line"`: ordering applies only to calls executed eagerly in the same file's class body — a
    # call inside a def body runs at invocation time, and a def in another file can never be ordered
    # against the call site, so both conservatively count as shadowing. A nil `call_node`
    # (position-less dispatch probes) does the same.
    def singleton_def_shadows_call?(class_name, method_name, call_node)
      def_shadows_call?(user_singleton_def_site_for(class_name, method_name), class_name, method_name,
                        :singleton, call_node)
    end

    # The instance-side twin of {#singleton_def_shadows_call?}: whether `class_name`'s `def method_name`
    # has run by call time — for `extend M` edges, where M's instance surface is what answers.
    def instance_def_shadows_call?(class_name, method_name, call_node)
      def_shadows_call?(user_def_site_for(class_name, method_name), class_name, method_name, :instance,
                        call_node)
    end

    # Shared ordering half of the two `*_def_shadows_call?` predicates, over this file's
    # `discovered_deferred_ranges` (issue #1097). `exists` — a recorded `"path:line"` site or the
    # method-existence table — says a def of `method_name`/`kind` on `class_name` is known at all; a
    # discovered def with no site (an `attr_*` sibling, a bundle seed that predates the table) counts
    # through `discovered_method?`. The ranges then answer the timing questions, and can supply defs
    # the site table missed (a `module_function`-installed `sig` never enters the singleton-def
    # table). A foreign-file site cannot be ordered against the call — shadowing. A nil `call_node`
    # (position-less dispatch probes) or a file the index never saw falls back to `exists`.
    def def_shadows_call?(site, class_name, method_name, kind, call_node)
      exists = !site.nil? || discovered_method?(class_name, method_name, kind)
      return exists if call_node.nil?

      path = source_path
      return exists unless path

      if site
        site_path, = site.rpartition(":")
        return true unless site_path == path
      end

      ranges = @discovery.discovered_deferred_ranges[path]
      return exists if ranges.nil?

      deferred_ranges_shadow_call?(ranges, method_name.to_sym, kind, class_name.to_s,
                                   call_node.location, exists)
    end
    private :def_shadows_call?

    # The range scan behind {#def_shadows_call?}. A call CONTAINED in any def / block / lambda /
    # `END` range is deferred — it runs at invocation time — so it is shadowed iff a matching def is
    # known (`exists`, or a row the site table missed). An EAGER call is shadowed iff the earliest
    # same-name, same-kind (`:both` matches either), same-OWNER row starts before it: owner scoping
    # keeps `class A`'s defs from ordering `class F`'s calls, and earliest-of keeps
    # `def self.sig; sig {}; def self.sig` honest where the def-node table is later-wins. With no
    # matching row the answer is `exists` — "a def exists but cannot be ordered" stays conservative,
    # "no def at all" stays permissive.
    def deferred_ranges_shadow_call?(ranges, method_name, kind, class_name, call_loc, exists)
      contained = false
      matching = false
      earliest = nil
      ranges.each do |(start, finish, name, def_kind, owner)|
        contained ||= start <= call_loc.start_offset && call_loc.end_offset <= finish
        next unless deferred_row_orders_call?(name, def_kind, owner, method_name, kind, class_name)

        matching = true
        earliest = start if earliest.nil? || start < earliest
      end
      return exists || matching if contained

      earliest.nil? ? exists : earliest <= call_loc.start_offset
    end
    private :deferred_ranges_shadow_call?

    # Whether a range row can order the call: same method name, same qualified owner, and a def kind
    # that answers this predicate's side (`:both` — `module_function` — matches either).
    def deferred_row_orders_call?(name, def_kind, owner, method_name, kind, class_name)
      name == method_name && owner == class_name && (def_kind == kind || def_kind == :both)
    end
    private :deferred_row_orders_call?

    # ADR-24 slice 2 — per-class table mapping a fully qualified user-class name to its superclass name AS WRITTEN
    # at the `class Foo < Bar` declaration (`"Bar"`, possibly a qualified `"A::B"`). Populated by `ScopeIndexer` —
    # per-file plus the cross-file project pre-pass — and consumed by
    # `ExpressionTyper#try_user_method_inference` to walk the superclass chain when an implicit-self call does not
    # resolve against the enclosing class's own defs. The as-written name is resolved to a qualified class at walk
    # time against the call's lexical nesting.
    def superclass_of(class_name)
      record_class_dependency(class_name) if Analysis::DependencyRecorder.active?
      @discovery.discovered_superclasses[class_name.to_s]
    end

    # ADR-48 — per-class table mapping a fully qualified class name to its ordered `Data.define` / `Struct.new`
    # member-name list. Populated by `ScopeIndexer` for both the constant-assigned form
    # (`Point = Data.define(:x, :y)`) and the named-subclass form (`class Point < Data.define(:x, :y)`). Consumed
    # by {Inference::MethodDispatcher::DataFolding} so `Point.new(...)` on a `Singleton[Point]` receiver
    # materialises a precise member instance. Returns nil when the class has no recorded layout.
    def data_member_layout(class_name)
      layout = @discovery.data_member_layouts[class_name.to_s]
      # Record the ancestry dependency only on a hit — DataFolding consults this for every `Singleton[*].new`,
      # and a miss (the common case: an ordinary class) must not manufacture a spurious cross-file edge.
      record_class_dependency(class_name) if layout && Analysis::DependencyRecorder.active?
      layout
    end

    # ADR-48 Struct follow-up — the `{ members:, keyword_init: }` layout recorded for a `Struct.new(...)`-defined
    # class, in the constant form (`Point = Struct.new(:x, :y)`) and the named-subclass form
    # (`class Point < Struct.new(:x, :y)`). Consumed by {Inference::MethodDispatcher::StructFolding} so
    # `Point.new(...)` on a `Singleton[Point]` receiver materialises a member instance. Returns nil when the class
    # has no recorded struct layout. Mirrors {#data_member_layout}'s dependency-recording contract.
    def struct_member_layout(class_name)
      layout = @discovery.struct_member_layouts[class_name.to_s]
      record_class_dependency(class_name) if layout && Analysis::DependencyRecorder.active?
      layout
    end

    # ADR-24 slice 2 — per-class/module table mapping a fully qualified user class or module to the list of
    # module names it `include`s / `prepend`s, in instance-ancestor SEARCH order: prepended modules first
    # (Ruby inserts them ahead of the class itself), then included modules nearest-first — `include A;
    # include B` searches B before A, while `include A, B` keeps `["A", "B"]` (each statement's argument
    # list lands as one unit, ahead of the earlier statements'). Populated by `ScopeIndexer` (per-file
    # plus the cross-file pre-pass) and consumed by `ExpressionTyper#resolve_user_def_through_ancestors` so an
    # implicit-self call resolves against an included module's `def`s, not just the superclass chain.
    # As-written names are resolved to qualified classes at walk time. Issue #1173 — the list was call
    # order until then, a divergence from Ruby's later-include-wins the order-sensitive consumers (the
    # BFS mixin step, the external-ancestor walk, override visibility) silently absorbed.
    def includes_of(class_name)
      record_class_dependency(class_name) if Analysis::DependencyRecorder.active?
      @discovery.discovered_includes[class_name.to_s] || []
    end

    # Issue #898 — the module names `extend`ed onto `class_name`'s SINGLETON, as written, gathered up the
    # as-written superclass chain because a singleton class inherits its superclass's singleton class
    # (`class Base; extend Comparable; end; class Widget < Base; end` leaves `Widget.is_a?(Comparable)`
    # true). Empty for a class the project never extends, and for every scope that saw no seeding pass.
    #
    # This is EVIDENCE FOR a singleton ancestor, never against one: the walk sees only what a constant
    # argument to a receiverless `extend` (or, since #915, a receiverless `include` / `prepend` inside a
    # `class << self` body) written inside a declaration body spells, so a runtime `Widget.extend(m)` and an
    # `extend` in a file outside the analysed set are both absent from it, as is an `extend` declared only
    # in RBS — that one reaches the same consumer through `Environment#singleton_extended_modules` instead.
    # Its one consumer ({Inference::Narrowing.narrow_class}) therefore reads it
    # only to WITHHOLD a `Bot`, and never to assert that a guard matches.
    def singleton_extends_of(class_name)
      table = @discovery.discovered_extends
      return [] if table.empty?

      names = []
      current = class_name.to_s
      seen = {}
      while current && !seen[current] && seen.size <= ANCESTOR_WALK_LIMIT
        seen[current] = true
        record_class_dependency(current) if Analysis::DependencyRecorder.active?
        names.concat(table[current] || [])
        current = @discovery.discovered_superclasses[current]
      end
      names.uniq
    end

    # ADR-24, amended for #1567 / #1568 / #1570 / #1571 — every reader below answers in Ruby's linearised
    # ancestor order, read from {ResolutionChain} (an internal class: `Scope`'s own surface is the plugin API
    # `spec/rigor/public_api_drift_spec.rb` pins, and the chain is not part of it). None walks `includes_of` /
    # `superclass_of` / the extends table itself; `spec/rigor/scope/ancestry_walker_detection_spec.rb` fails on
    # a method that does. Each keeps its signature and its return type exactly: only WHICH definer it answers
    # moved. `name_memo:` is still accepted and no longer needed — the chain memoises name resolution itself.
    UNUSED_NAME_MEMO = {}.freeze
    private_constant :UNUSED_NAME_MEMO
    #
    # Every reader below asks {ResolutionChain#settle} whether its chain answer stands, and where it does not
    # answers what the walk it replaced answered ({ResolutionChain::MasterOrder}) — the tables cannot say which
    # world ran, and a disagreement is no reason to answer anything new.

    # ADR-24 slice 2 — the user-side method lookup: the first project `def` of `method_name` along
    # `class_name`'s instance chain, as `[def_node, owner]`, or `[nil, nil]` when nothing the project declares
    # defines it. An external ancestor is passed over, as before: a caller asking "does the project define
    # this" must not read an RBS module's declaration as absence (#1572 is the typing read that will stop
    # there).
    #
    # It lives HERE, not in a consumer, because it reads nothing but this scope's frozen discovery index — the
    # property that lets `ExpressionTyper` memoise its results run-wide. `ExpressionTyper#compute_user_def_with_owner`
    # wraps it in that memo for the dispatch hot path, and {Inference::MethodDispatcher::StructMaterialization}'s
    # `.with` guard reads the same answer (#598 review).
    #
    # #1567 — the walk was breadth-first until the chain replaced it: `class C < Base; include A` with `A`
    # including `M` answered `Base#foo` where Ruby calls `M#foo`. The prepend wedge #1123 added (a prepended
    # module searched ahead of the class's own `def`s) and the include search order #1173 fixed are both
    # positions on the chain now, at every class on it.
    def user_def_through_ancestors(class_name, method_name, name_memo: UNUSED_NAME_MEMO) # rubocop:disable Lint/UnusedMethodArgument
      chain = ResolutionChain.for(self, class_name.to_s, :instance, :methods)
      found = first_user_def(chain, method_name)
      owner = found&.last
      if chain.settle(self, owner, owner: owner) { |retro| first_user_def(retro, method_name)&.last } == :master
        found = master_user_def(class_name.to_s, method_name)
      end
      return found if found

      chain.truncated? ? ancestor_walk_gave_up : [nil, nil]
    end

    def first_user_def(chain, method_name)
      chain.search(self) do |entry|
        next if entry.external?

        node = user_def_for(entry.name, method_name)
        [node, entry.name] if node
      end
    end

    def master_user_def(class_name, method_name)
      names = ResolutionChain::MasterOrder.definer_sequence(self, class_name)
      names.each { |name| record_class_dependency(name) } if Analysis::DependencyRecorder.active?
      names.each do |name|
        node = user_def_for(name, method_name)
        return [node, name] if node
      end
      nil
    end
    private :first_user_def, :master_user_def

    # Issue #731 — the singleton-side twin of {#user_def_through_ancestors}: the first `def self.` /
    # `class << self` body of `method_name` along `class_name`'s singleton chain, as `[def_node, owner]`, or
    # `[nil, nil]` — each class object's own table, then the modules it extends in Ruby's order, then the
    # superclass's. `ScopeIndexer` folds an extended module's own `def`s into the extender's table, so those
    # answer at the extender; a module the extended one includes is its own entry (#1567's singleton shape:
    # `class C < Base; extend A` with `A` including `M` is `M#foo`, not `Base.foo`). Where the chain does
    # not stand, the answer is the class objects' alone, as the superclass-only walk this replaced gave.
    def singleton_def_through_ancestors(class_name, method_name, name_memo: UNUSED_NAME_MEMO) # rubocop:disable Lint/UnusedMethodArgument
      chain = ResolutionChain.for(self, class_name.to_s, :singleton, :methods)
      found = first_singleton_def(chain, method_name)
      owner = found&.last
      if chain.settle(self, owner, owner: owner) { |retro| first_singleton_def(retro, method_name)&.last } == :master
        found = first_singleton_def(chain, method_name, :singleton)
      end
      return found if found

      chain.truncated? ? ancestor_walk_gave_up : [nil, nil]
    end

    def first_singleton_def(chain, method_name, side = nil)
      chain.search(self, side: side) do |entry|
        next if entry.external?

        name = entry.name
        node = entry.side == :singleton ? singleton_def_for(name, method_name) : user_def_for(name, method_name)
        [node, entry.name] if node
      end
    end
    private :first_singleton_def

    # Issue #633 — the ancestors a project class reaches that the project itself does NOT declare: the
    # `< StandardError` / `< Array` superclasses and the `include Comparable` mixins, as the CANDIDATE LIST for
    # each as-written name ({#ancestor_name_candidates}: the nesting spellings first, the bare name last), in
    # Ruby's order along the instance chain — the order the caller that adopts the FIRST answering one (#1173)
    # depends on. Resolving a candidate means asking the RBS environment, which this frozen-index read does
    # not do; the caller takes the first candidate its own oracle knows. Where the chain does not stand, the
    # groups are the depth-first ones the walk this replaced emitted.
    #
    # Issue #527 slice 1 — `mixins: false` answers the superclass edge only: a consumer resolving one KIND of
    # inheritance edge at a time (the dispatch arm lands `< Hash` before `include Enumerable`) narrows it, and
    # records only the superclass chain it read.
    def external_ancestor_name_candidates(class_name, name_memo: UNUSED_NAME_MEMO, mixins: true) # rubocop:disable Lint/UnusedMethodArgument
      chain = ResolutionChain.for(self, class_name.to_s, :instance, :methods)
      groups = external_groups(chain, mixins)
      if chain.settle(self, groups) { |retro| external_groups(retro, mixins) } == :master
        groups = ResolutionChain::MasterOrder.external_groups(self, class_name.to_s, mixins)
      end
      if Analysis::DependencyRecorder.active?
        mixins ? chain.record(self) : chain.level_classes.each { |name| record_class_dependency(name) if name }
      end
      # Issue #527 — the cut is a budget event, not an answer: consumers read the groups as "the ancestors
      # this class reaches", so a short list must be visible in `--stats` beside the other walks' exhaustions.
      Inference::BudgetTrace.hit(Inference::BudgetTrace::ANCESTOR_WALK_LIMIT) if chain.truncated?
      groups
    end

    def external_groups(chain, mixins)
      chain.entries.filter_map { |entry| entry.candidates if entry.external? && (mixins || entry.superclass_edge) }
    end
    private :external_groups

    # The budget {ResolutionChain::LIMIT} enforces; a hierarchy past it gives up rather than reading an answer
    # off a cut chain (ADR-41 WD4).
    ANCESTOR_WALK_LIMIT = ResolutionChain::LIMIT

    EMPTY_HEADER_NESTING = [].freeze
    private_constant :EMPTY_HEADER_NESTING

    def ancestor_walk_gave_up
      Inference::BudgetTrace.hit(Inference::BudgetTrace::ANCESTOR_WALK_LIMIT)
      [nil, nil]
    end
    private :ancestor_walk_gave_up

    # Issue #723 — the question {#user_def_through_ancestors} asks, asked of the DISCOVERY table rather than
    # the def-node table: does the project define `method_name` on `class_name` or on any ancestor the project
    # itself declares? The two tables are not interchangeable — `discovered_methods` also carries
    # `define_method`, `attr_*` and the whole singleton side, none of which contributes a `Prism::DefNode` —
    # and the suppression probe shared by the `call.*` check rules needs the broader one.
    #
    # Why it must walk at all: `Analysis::CheckRules#source_declared_method?` asked `discovered_method?`,
    # which is keyed on the receiver's OWN name, while the typer resolves the same call through this
    # ancestry. A project class whose `sig/` declares it without its project superclass therefore drew
    # `call.undefined-method` on a method `dump_type` resolved on the same line of the same run — writing
    # MORE RBS made the run worse, the incentive #653 removed for plugin-typed calls.
    #
    # `kind: :singleton` reads the singleton chain: the class objects' own methods (an extended module's are
    # folded into its extender's) and the instance methods of the modules they extend and those modules'
    # includes. Existence is a union, so the chain's two worlds, which hold the same modules, agree on it.
    def discovered_method_through_ancestors?(class_name, method_name, kind, name_memo: UNUSED_NAME_MEMO) # rubocop:disable Lint/UnusedMethodArgument
      return false if class_name.nil?

      chain = ResolutionChain.for(self, class_name.to_s, kind == :singleton ? :singleton : :instance, :methods)
      found = chain.search(self) do |entry|
        next false if entry.external?

        discovered_method?(entry.name, method_name, entry.side == :singleton ? :singleton : kind_for(kind))
      end
      return true if found
      # Budget exhaustion is uncertainty, not absence: answering "not declared" here would hand a
      # `call.undefined-method` a fired verdict it has no evidence for. Suppress and record the hit.
      return false unless chain.truncated?

      Inference::BudgetTrace.hit(Inference::BudgetTrace::ANCESTOR_WALK_LIMIT)
      true
    end

    # A module entry on the singleton chain answers with its INSTANCE methods; on the instance chain, the
    # caller's kind stands.
    def kind_for(kind) = kind == :singleton ? :instance : kind
    private :kind_for

    # Pushes `current`'s direct ancestors onto a breadth-first queue: included / prepended modules first, then
    # the superclass, each resolved against the nesting `current`'s declaration header is written in; names
    # that resolve to no project class/module are dropped. `mixins: false` gives the superclass alone. No
    # reader in the engine walks this way any more (they read {ResolutionChain}); it stays for the plugin
    # surface, with the ADR-46 class edge the walk it served always filed.
    def enqueue_ancestors(current, queue, name_memo, mixins: true) # rubocop:disable Lint/UnusedMethodArgument
      record_class_dependency(current) if Analysis::DependencyRecorder.active?
      queue.concat(ResolutionChain.direct_ancestors(self, current.to_s, mixins))
    end

    # Issue #682 — the candidate names an ancestor spelled `raw_ancestor` can denote in `subclass_qualified`,
    # in Ruby's lookup order, most-qualified first and the bare name last. The single owner of the question:
    # three walks resolved a superclass / include name apiece (the method walk, the constant ladder's
    # ancestor rung, and `Analysis::CheckRules`' override-visibility rule — all three now {ResolutionChain}),
    # and each derived the order by PEELING the subclass's qualified name one `::` segment at a time.
    #
    # That peel is the NESTED spelling's answer, given to both spellings. Ruby evaluates a superclass
    # expression before entering the body, so the cref that governs it is the one the declaration's HEADER
    # is written in — `Module.nesting` minus the declaration's own entry. For `module Admin; class Widget <
    # Base` that is `["Admin"]` and the peel agrees; for the compact `class Admin::Widget < Base` written at
    # the top level it is EMPTY, and the peel searched an `Admin::Base` Ruby never looks at — a wrong class
    # for the ancestor rung of constant lookup and for method dispatch alike.
    #
    # The header nesting is a property of the DECLARATION, not of the reader, so it is read from the
    # discovery table `Inference::ScopeIndexer` records it in rather than from this scope's own
    # `#lexical_nesting`. Answering off the reader's chain would be wrong past the first hop of the ancestor
    # chain (the chain describes the reader's class, not the ancestor being resolved) and would silently
    # corrupt the {ResolutionChain} memo and the ones layered on it (`Inference::ExpressionTyper#class_graph_buckets`,
    # `Reflection.ancestor_constant_scopes`), all of which key on the class name alone because this walk is
    # a pure function of the frozen discovery tables.
    #
    # The peel survives as the FALLBACK, for a class no declaration walk recorded — a scope seeded without
    # the table, an anonymous `Class.new` name, a class reached only through RBS. It is the same answer this
    # walk gave before, so an unrecorded class is unchanged rather than degraded.
    #
    # An include / prepend name is written INSIDE the body, so Ruby also tries `<subclass>::<raw>` ahead of
    # everything here. That rung is deliberately still missing — it was missing from the peel too, and
    # adding it is a widening this change does not need.
    def ancestor_name_candidates(subclass_qualified, raw_ancestor)
      # Issue #722 residue 1 / #637 — a ROOTED ancestor name is anchored at the top level and has no
      # candidate list: `class Rooted < ::Base` names `::Base` wherever it is written, exactly as
      # `Source::ConstantPath.declaration_prefix` already re-anchors a rooted HEADER. The marker is the
      # leading `::` `Inference::ScopeIndexer.recorded_ancestor_name` preserves.
      raw = raw_ancestor.to_s
      return [raw.delete_prefix("::")] if raw.start_with?("::")

      recorded = @discovery.discovered_header_nestings[subclass_qualified.to_s]
      entries = recorded ? recorded_header_nesting(recorded, raw) : peeled_header_nesting(subclass_qualified)
      if !entries.empty? && DiscoveryIndex.ambiguous_header_nesting?(entries)
        return ambiguous_ancestor_candidates(entries, raw_ancestor)
      end

      entries.map { |entry| "#{entry}::#{raw_ancestor}" } << raw_ancestor.to_s
    end

    # Issue #986 — the candidate list for a raw name two declaration sites of ONE class wrote in different
    # crefs (the compact-header rename pass landed both on this key). Each alternative chain gets its own
    # candidate list, in the order this walk would have used for that site alone.
    #
    # When two of them resolve to two DIFFERENT project classes there is no candidate list to return: at
    # runtime both `include`s run, and which of the two same-named modules ends up nearer in the MRO is the
    # load order of the two files, which this walk cannot know. Answering with either is a WRONG ANCESTOR,
    # and a wrong ancestor is a false-positive source rather than a missed one — two same-named modules can
    # declare the same method at different arities, and `call.wrong-arity` then fires on a correct program.
    # The empty list declines instead: the name resolves to no project class, the receiver's methods stay
    # `Dynamic`, and every rule reading this walk goes quiet.
    #
    # Where the alternatives AGREE, or only one of them resolves at all, there is nothing to adjudicate: the
    # answer is the union of their chains, most-qualified first — the same list a class whose sites needed
    # no rename gets — so an unambiguous collision is unchanged, and an EXTERNAL ancestor keeps the full
    # candidate list `#external_ancestor_name_candidates` hands the gem / RBS probe.
    def ambiguous_ancestor_candidates(alternatives, raw_ancestor)
      return [] if ambiguous_ancestor_resolutions_of(alternatives, raw_ancestor).size > 1

      entries = alternatives.reduce([], :|).sort_by { |entry| [-entry.split("::").size, entry] }
      entries.map { |entry| "#{entry}::#{raw_ancestor}" } << raw_ancestor.to_s
    end

    def ambiguous_ancestor_resolutions_of(alternatives, raw_ancestor)
      alternatives.filter_map do |chain|
        (chain.map { |entry| "#{entry}::#{raw_ancestor}" } << raw_ancestor.to_s)
          .find { |candidate| known_user_class?(candidate) }
      end.uniq
    end
    private :ambiguous_ancestor_candidates, :ambiguous_ancestor_resolutions_of

    # Issue #986 — the several project classes an ancestor name resolves to when the compact-header rename
    # collision left it ambiguous, and `EMPTY_HEADER_NESTING` for every other name. {#ancestor_name_candidates}
    # declines such a name because no ONE class is its answer; a caller that also knows which METHOD it is
    # looking up can do better than that decline, and a rule that reports on a method must, because the
    # decline otherwise silences it for the whole receiver — its own `def`s and its unambiguous ancestors
    # included.
    #
    # Both of these classes are ancestors at runtime: both `include`s run, and only their MRO ORDER is the
    # load order this walk cannot see. So a method only one of them declares is answered by that one
    # whatever the order, and only a method they BOTH declare is unanswerable.
    # `Analysis::CheckRules::SourceArity` reads this for exactly that: it takes both as mixin levels and
    # declines on the disagreement its own envelope join already knows how to spot.
    def ambiguous_ancestor_resolutions(subclass_qualified, raw_ancestor)
      raw = raw_ancestor.to_s
      return EMPTY_HEADER_NESTING if raw.start_with?("::")

      recorded = @discovery.discovered_header_nestings[subclass_qualified.to_s]
      return EMPTY_HEADER_NESTING if recorded.nil?

      entries = recorded_header_nesting(recorded, raw)
      return EMPTY_HEADER_NESTING if entries.empty? || !DiscoveryIndex.ambiguous_header_nesting?(entries)

      resolved = ambiguous_ancestor_resolutions_of(entries, raw_ancestor)
      resolved.size > 1 ? resolved : EMPTY_HEADER_NESTING
    end

    # Issue #728 — the chain of the declaration site that WROTE `raw`, which is the cref Ruby resolves that
    # one name in. A class's sites need not agree: `class Foo < Base` at the top level and a rooted
    # `class ::Foo; include Helper; end` inside `module Outer` are two sites of `Foo`, and the union of
    # their chains put `Outer::Base` — a class Ruby never looks at — ahead of `::Base` for the superclass
    # the top-level site wrote. That is a WRONG CLASS, not a wider candidate list.
    #
    # The unkeyed entry is the union, and answers a name no site recorded under its own key: an `include`
    # attributed to this class from OUTSIDE its declaration (`Recv.class_eval { include M }`, which
    # `Inference::ScopeIndexer#walk_class_includes` names but the header walk cannot see), or a dynamic
    # mixin argument. It is the pre-#728 answer, so those are unchanged rather than degraded.
    def recorded_header_nesting(bucket, raw)
      bucket[raw] || bucket[DiscoveryIndex::UNKEYED_HEADER_NESTING] || EMPTY_HEADER_NESTING
    end
    private :recorded_header_nesting

    # The pre-#682 reading of a qualified class name: every proper prefix of it, innermost first, as if the
    # class had been declared one `module` keyword per segment.
    def peeled_header_nesting(subclass_qualified)
      segments = subclass_qualified.to_s.split("::")
      (segments.length - 1).downto(1).map { |i| segments[0, i].join("::") }
    end
    private :peeled_header_nesting

    # Issue #723 — `discovered_methods` is in the list because the other three miss a class whose only
    # project-side content is CLASS methods: `class Base; def self.build = :built; end` records no instance
    # def node, no superclass and no include, so the ancestor-name resolver did not recognise `Base` as a
    # project class at all and every walk through it ended one hop early. The table that answers "the
    # project defines something here" on both sides is this one.
    def known_user_class?(name)
      discovered_superclasses.key?(name) || discovered_def_nodes.key?(name) ||
        discovered_includes.key?(name) || discovered_methods.key?(name)
    end
    # `known_user_class?` is PUBLIC (issue #530): `Inference::ExpressionTyper`'s external-gem ancestry probe
    # has to ask the same "is this name a project class?" question this walk asks, and answering it with a
    # narrower predicate (`discovered_classes` alone) would read a project class as having left the project
    # and attribute its root name to a same-named locked gem — a WRONG provenance label, which is the one
    # direction ADR-82 forbids.

    # Records, for a resolved cross-class ancestry read, every file that declares `class_name` (its declaration /
    # reopening / superclass / include sites). The `discovered_class_sources` table it reads is populated by the
    # cross-file project pre-pass ({Inference::ScopeIndexer.discovered_def_index_for_paths}); a scope built
    # without one holds none, and the read then files nothing. No-op when the class is not a project class
    # (core / stdlib / gem names never appear in the source map). Gated by the caller on the recorder being
    # active.
    def record_class_dependency(class_name)
      sites = @discovery.discovered_class_sources[class_name.to_s]
      return if sites.nil?

      sites.each { |site| Analysis::DependencyRecorder.read_site(site) }
    end
    private :record_class_dependency

    # Issue #639 — the EXISTENCE edge for a bare class reference, `class:<last segment>`, the hit-side twin of
    # the miss-side key `Inference::ExpressionTyper` already records. ADR-46 slice 1c left the existence hit
    # edgeless on the reasoning that a file merely referencing `Post` depends on `Post`'s methods, not on its
    # bare existence; that stops holding the moment the DECLARING FILE IS DELETED, because existence is then
    # exactly what changed and a reference-only consumer had recorded nothing to be re-checked by.
    #
    # NAME-keyed rather than a positive edge to the declaring file, which is the distinction the ADR's cost
    # argument turns on: the declared-class set of a file does not move when a method body in it is edited,
    # so a bare referent is re-checked when the class appears or disappears and at no other time. A file edge
    # would have re-checked every bare referent of every class the file declares on any edit to it.
    def record_class_existence(class_name)
      Analysis::DependencyRecorder.read_last_segment(:class, class_name.to_s)
    end

    # Issue #644 — the positive ADR-46 edge for a cross-file VALUE constant. `Reflection.constant_type_at`
    # calls this the moment a candidate resolves through `in_source_constants`, so the reader depends on the
    # file that wrote the constant: editing the literal, or deleting the file, re-checks the reader. Recorded
    # WITHOUT a symbol (a file-granularity / ancestry edge) because a constant's published value is a
    # declaration-level fact of the whole file, which is also the granularity
    # `ScopeIndexer#append_constant_signature` moves the declaration signature at.
    #
    # `constant_sources` is seeded only when dependency recording is on, so on every ordinary run the table
    # is empty and this is one Hash miss; the caller additionally gates on the recorder being active.
    def record_constant_dependency(name)
      sites = @discovery.constant_sources[name]
      return if sites.nil?

      sites.each { |site| Analysis::DependencyRecorder.read_site(site) }
    end

    # Issue #992 — one class's `discovered_parameter_envelopes` bucket (`{[kind, method_name] => envelope}` plus
    # the class-wide marks), or an empty Hash. Records the ADR-46 class edge first: a verdict read off the
    # bucket depends on every file that declares the class, and a `memoize :f` added to one of them moves it.
    def parameter_envelopes_of(class_name)
      record_class_dependency(class_name) if Analysis::DependencyRecorder.active?
      @discovery.discovered_parameter_envelopes[class_name.to_s] || EMPTY_PARAMETER_ENVELOPES
    end

    EMPTY_PARAMETER_ENVELOPES = {}.freeze
    private_constant :EMPTY_PARAMETER_ENVELOPES

    # v0.1.2 — per-class table mapping `method_name (Symbol) → :public | :private | :protected`. Populated by
    # `ScopeIndexer` for every `def` it sees inside a class body, with the visibility taken from the surrounding
    # `private` / `protected` / `public` modifier state plus any post-hoc `private :name, ...` named-argument
    # calls. Consumed by the `def.method-visibility-mismatch` rule so explicit-non-self calls to a private method
    # surface a diagnostic.
    def discovered_method_visibility(class_name, method_name)
      table = @discovery.discovered_method_visibilities[class_name.to_s]
      return nil unless table

      table[method_name.to_sym]
    end

    # Closes the "`params[:f] ||= []; params[:f] << x`" precision gap (ROADMAP § Type-language / engine —
    # indexed-collection narrowing through `Hash[k] ||= default`). After `receiver[key] ||= default`, the next
    # read at `receiver[key]` is known non-nil; recording the post-`||=` type keyed on
    # `(receiver_kind, receiver_name, literal_key)` lets the ExpressionTyper's `[]` dispatch hand back the
    # narrowed type. Receiver-rebind and `[]=`/mutator invalidation rules are documented at the call sites in
    # `Inference::StatementEvaluator`.
    def indexed_narrowing(receiver_kind, receiver_name, key)
      @indexed_narrowings[indexed_key(receiver_kind, receiver_name, key)]
    end

    def with_indexed_narrowing(receiver_kind, receiver_name, key, type)
      new_table = @indexed_narrowings.merge(
        indexed_key(receiver_kind, receiver_name, key) => type
      ).freeze
      rebuild(indexed_narrowings: new_table)
    end

    def without_indexed_narrowing(receiver_kind, receiver_name, key)
      lookup = indexed_key(receiver_kind, receiver_name, key)
      return self unless @indexed_narrowings.key?(lookup)

      new_table = @indexed_narrowings.reject { |k, _| k == lookup }.freeze
      rebuild(indexed_narrowings: new_table)
    end

    def without_indexed_narrowings_for(receiver_kind, receiver_name)
      new_table = drop_indexed_narrowings_for(receiver_kind, receiver_name)
      return self if new_table.equal?(@indexed_narrowings)

      rebuild(indexed_narrowings: new_table)
    end

    # Closes the "stable receiver method-chain narrowing" gap (ROADMAP § Future cycles / Type-language / engine —
    # "Method-call receiver narrowing across stable receivers"; 2026-05-28 Redmine survey). After
    # `if x.last.is_a?(Array)` the dominated body's `x.last` reads MUST observe the truthy-narrowed type; the same
    # chain reaching the falsey edge observes the negative narrowing.
    #
    # Address shape mirrors {.indexed_narrowing}: stable root variable + no-arg single-hop method name. See
    # {ChainKey} for the precise contract.
    def method_chain_narrowing(receiver_kind, receiver_name, method_name)
      @method_chain_narrowings[chain_key(receiver_kind, receiver_name, method_name)]
    end

    def with_method_chain_narrowing(receiver_kind, receiver_name, method_name, type)
      new_table = @method_chain_narrowings.merge(
        chain_key(receiver_kind, receiver_name, method_name) => type
      ).freeze
      rebuild(method_chain_narrowings: new_table)
    end

    def without_method_chain_narrowing(receiver_kind, receiver_name, method_name)
      lookup = chain_key(receiver_kind, receiver_name, method_name)
      return self unless @method_chain_narrowings.key?(lookup)

      new_table = @method_chain_narrowings.reject { |k, _| k == lookup }.freeze
      rebuild(method_chain_narrowings: new_table)
    end

    def without_method_chain_narrowings_for(receiver_kind, receiver_name)
      new_table = drop_chain_narrowings_for(receiver_kind, receiver_name)
      return self if new_table.equal?(@method_chain_narrowings)

      rebuild(method_chain_narrowings: new_table)
    end

    def facts_for(target: nil, bucket: nil)
      fact_store.facts_for(target: target, bucket: bucket)
    end

    def local_facts(name, bucket: nil)
      facts_for(target: Analysis::FactStore::Target.local(name), bucket: bucket)
    end

    def type_of(node, tracer: nil)
      Inference::ExpressionTyper.new(scope: self, tracer: tracer).type_of(node)
    end

    # ADR-89 WD2 — the inferred return type of `def_node` called with `receiver` / `arg_types`, computed
    # against THIS scope's discovery index (so cross-file dispatches in the body resolve). The incremental
    # session re-drives a declaration-stable changed callee at each previously-observed call key to prove its
    # return is unchanged before skipping its symbol dependents.
    def user_method_return(def_node, receiver, arg_types)
      Inference::ExpressionTyper.new(scope: self).return_type_for(def_node, receiver, arg_types)
    end

    # Statement-level evaluation: returns the pair `[type, scope']` where `type` is what the node produces and
    # `scope'` is the scope observable after the node has run. The receiver scope is never mutated. See
    # {Rigor::Inference::StatementEvaluator} for the catalogue of nodes that thread scope; everything else defers
    # to {#type_of} and returns the receiver scope unchanged.
    def evaluate(node, tracer: nil)
      Inference::StatementEvaluator.new(scope: self, tracer: tracer).evaluate(node)
    end

    # Joins this scope with another at a control-flow merge point. The joined scope is bound to every local that
    # BOTH branches bind, with the type widened to the union of both sides. Names bound in only one branch are
    # dropped from the joined scope; the eventual statement-level evaluator (Slice 3 phase 2) is responsible for
    # nil-injecting half-bound names where the language semantics demand it. The two scopes MUST share the same
    # Environment.
    def join(other)
      raise ArgumentError, "join requires a Rigor::Scope, got #{other.class}" unless other.is_a?(Scope)

      unless environment.equal?(other.environment)
        raise ArgumentError, "join requires both scopes to share the same Environment"
      end

      joined_locals = join_bindings(locals, other.locals)
      joined_ivars = join_bindings(ivars, other.ivars)
      joined_cvars = join_bindings(cvars, other.cvars)
      joined_globals = unbind_split_last_line(join_bindings(globals, other.globals), other)
      build_joined_scope(joined_locals, joined_ivars, joined_cvars, joined_globals, other)
    end

    # Issue #1429 — a join keeps a guard record while the joined scope still narrows its name: a global both arms
    # bind, a constant both arms narrow (one an arm does not narrow reads its resolved type after the join, so its
    # narrowing is gone), and an instance variable both arms bind (#1446). An arm without a record contributes nothing
    # to the restore target, whose union with the joined binding {#forget_guard_narrowings} takes, so it still covers
    # that arm's binding.
    # `joined` maps each record kind to the joined scope's table of that kind.
    def join_guard_records(other, joined)
      mine = @guard_records
      theirs = other.guard_records
      return EMPTY_GUARD_RECORDS if mine.empty? && theirs.empty?

      merged = mine.merge(theirs) { |_key, left, right| Type::Combinator.union(left, right) }
      kept = merged.select { |(kind, name), _| joined.fetch(kind).key?(name) }
      kept.empty? ? EMPTY_GUARD_RECORDS : kept.freeze
    end
    private :join_guard_records

    # Issue #1359 — arms that bind `$_` apart join with it unbound rather than to their union. The arms of a reader
    # condition bind `String` and `nil`, and `String?` after `if gets … end` would report correct code that proves the
    # line some other way (`ok = gets ? true : false; return unless ok; line = $_; line.chomp`).
    def unbind_split_last_line(joined, other)
      return joined unless joined.key?(LAST_LINE) && @globals[LAST_LINE] != other.globals[LAST_LINE]

      joined.except(LAST_LINE).freeze
    end
    private :unbind_split_last_line

    def ==(other)
      other.is_a?(Scope) &&
        environment.equal?(other.environment) &&
        @locals == other.locals &&
        fact_store == other.fact_store &&
        self_type == other.self_type &&
        @ivars == other.ivars &&
        @cvars == other.cvars &&
        @globals == other.globals &&
        @indexed_narrowings == other.indexed_narrowings &&
        @method_chain_narrowings == other.method_chain_narrowings &&
        same_marks?(other)
    end
    alias eql? ==

    def hash
      [Scope, environment.object_id, @locals, fact_store, self_type, @ivars, @cvars, @globals].hash
    end

    private

    # The marks {#==} compares: ADR-58's, issue #667's and the repeated `||=` sites, and #1429's guard state.
    def same_marks?(other)
      @declaration_sourced == other.declaration_sourced &&
        @published_constant_sourced == other.published_constant_sourced &&
        @repeated_or_writes == other.repeated_or_writes &&
        same_guard_state?(other)
    end

    def same_guard_state?(other)
      @constant_narrowings == other.constant_narrowings && @guard_records == other.guard_records &&
        @bot_guard_classes == other.bot_guard_classes
    end

    def rebuild(
      locals: @locals, fact_store: @fact_store, self_type: @self_type,
      ivars: @ivars, cvars: @cvars, globals: @globals,
      discovery: @discovery,
      indexed_narrowings: @indexed_narrowings,
      method_chain_narrowings: @method_chain_narrowings,
      declaration_sourced: @declaration_sourced,
      published_constant_sourced: @published_constant_sourced,
      source_path: @source_path,
      struct_fold_safe_locals: @struct_fold_safe_locals,
      opaque_block_self: @opaque_block_self,
      singleton_class_body: @singleton_class_body,
      lexical_nesting: @lexical_nesting,
      dynamic_origins: @dynamic_origins,
      local_origins: @local_origins,
      ivar_origins: @ivar_origins,
      void_origins: @void_origins,
      plugin_typed_calls: @plugin_typed_calls,
      optimistic_origins: @optimistic_origins,
      optimistic_locals: @optimistic_locals,
      optimistic_ivars: @optimistic_ivars,
      repeated_or_writes: @repeated_or_writes,
      match_frame: @match_frame,
      constant_narrowings: @constant_narrowings,
      guard_records: @guard_records,
      bot_guard_classes: @bot_guard_classes
    )
      self.class.new(
        environment: environment, locals: locals,
        fact_store: fact_store, self_type: self_type,
        ivars: ivars, cvars: cvars, globals: globals,
        discovery: discovery,
        indexed_narrowings: indexed_narrowings,
        method_chain_narrowings: method_chain_narrowings,
        declaration_sourced: declaration_sourced,
        published_constant_sourced: published_constant_sourced,
        source_path: source_path,
        struct_fold_safe_locals: struct_fold_safe_locals,
        opaque_block_self: opaque_block_self,
        singleton_class_body: singleton_class_body,
        lexical_nesting: lexical_nesting,
        dynamic_origins: dynamic_origins,
        local_origins: local_origins,
        ivar_origins: ivar_origins,
        void_origins: void_origins,
        plugin_typed_calls: plugin_typed_calls,
        optimistic_origins: optimistic_origins,
        optimistic_locals: optimistic_locals,
        optimistic_ivars: optimistic_ivars,
        repeated_or_writes: repeated_or_writes,
        match_frame: match_frame,
        constant_narrowings: constant_narrowings,
        guard_records: guard_records,
        bot_guard_classes: bot_guard_classes
      )
    end

    def join_bindings(left, right)
      # Keys present in both, unioned. Iterating `left` and probing `right.key?` yields the same keys in the same
      # order as the prior `(left.keys & right.keys)` while avoiding the two key arrays and the intersection
      # array — this is the control-flow join, run at every branch merge, and was a top allocation site (~75% of
      # `Hash#keys`).
      result = {}
      left.each do |name, ltype|
        next unless right.key?(name)

        result[name] = Type::Combinator.union(ltype, right[name])
      end
      result.freeze
    end

    def build_joined_scope(joined_locals, joined_ivars, joined_cvars, joined_globals, other)
      self.class.new(
        environment: @environment,
        locals: joined_locals.freeze,
        fact_store: fact_store.join(other.fact_store),
        self_type: self_type == other.self_type ? self_type : nil,
        ivars: joined_ivars,
        cvars: joined_cvars,
        globals: joined_globals,
        discovery: @discovery,
        indexed_narrowings: join_bindings(@indexed_narrowings, other.indexed_narrowings),
        method_chain_narrowings: join_bindings(@method_chain_narrowings, other.method_chain_narrowings),
        # ADR-58 WD1 — a ref is declaration-sourced after a join only when BOTH branches agree it is. If either
        # path made the binding flow-live (a method-local nil write / failed-guard narrowing), the merge is
        # flow-live and `possible-nil-receiver` fires as before.
        declaration_sourced: join_declaration_sourced(other),
        # Issue #667 — UNION, the opposite of the line above, which is the first reason this mark does not
        # ride the ADR-58 Set. The mark only ever WITHHOLDS a firing, so keeping it when either arm bound the
        # name from a published constant is the false-positive-safe merge: `if c then m = MODE else m = MODE2
        # end; m == :x` must not warn because one arm's copy is invisible to the reader's author. ADR-67
        # WD6b's `:inferred_param` taint takes the same direction for the same reason.
        published_constant_sourced: join_published_constant_sourced(other),
        source_path: @source_path,
        # Issue #589 — the fold-safe set MUST survive a merge. It was simply absent from this constructor
        # call, so it fell back to the empty default and every `if` / `while` in a method silently revoked
        # struct member folding for the whole body after it: `s = S.new("r"); while c; i += 1; end; s.raw`
        # answered `Dynamic[top]` while the straight-line sibling folded to `"r"`. The carrier was never
        # the casualty — `s` still reads `S(raw: "r")` at the merge — only the grant that lets a read
        # consult it, which is why the shape looked like carrier erasure from the outside.
        #
        # The set is a property of the method BODY (a static scan over its root, stamped once by
        # `ScopeIndexer` / `StatementEvaluator` and threaded by `rebuild`), so both arms of a merge
        # normally carry the identical set and the intersection below is that set. Intersecting rather
        # than unioning is the FP-safe direction anyway: the grant licenses a FOLD, so retaining one an
        # arm did not have could fold a stale constant, while dropping one only costs precision.
        struct_fold_safe_locals: join_struct_fold_safe(other),
        # Issue #600 — the sibling omission of the same class, and the same failure mode: absent from this
        # constructor call, the flag fell back to `false`, so ANY merge inside a block re-armed the #316/#319
        # decline gate. `RSpec.describe do; if c; end; output; end` bound a cross-file top-level `def output`
        # again after the `if`, which is the wrong-bind direction the gate exists to prevent — the block's real
        # `self` may have gained a public same-named method by `include`, and that wins the MRO over the
        # private `Object` def.
        #
        # `||`, not `&&`: opacity is the DECLINING state, so keeping it once either arm has it is the FP-safe
        # merge. Like the fold-safe set this is normally a property of the enclosing block (stamped once at
        # block entry by `entering_opaque_block` and inherited through `rebuild`), so both arms usually carry
        # the same value and the `||` is that value.
        opaque_block_self: @opaque_block_self || other.opaque_block_self,
        # Issue #963 — a body property like the two above, so both arms of an in-body merge carry the identical
        # value and the `||` is that value. `||` is also the safe direction on its own terms: keeping the mark
        # declines the `define_method` narrowing, which is the pre-#963 answer.
        singleton_class_body: @singleton_class_body || other.singleton_class_body,
        # Issue #652 — the recorded `Module.nesting`, stamped once at body entry and threaded by `rebuild`
        # exactly as the fold-safe set is. A join is a control-flow merge INSIDE one body, so both arms
        # always carry the identical chain; taking this scope's is that chain. Dropping it would silently
        # re-enable the name-peel for everything after the first `if` in a body.
        lexical_nesting: @lexical_nesting,
        dynamic_origins: @dynamic_origins,
        local_origins: join_origins(@local_origins, other.local_origins),
        ivar_origins: join_origins(@ivar_origins, other.ivar_origins),
        void_origins: @void_origins,
        plugin_typed_calls: @plugin_typed_calls,
        optimistic_origins: @optimistic_origins,
        optimistic_locals: join_optimistic_marks(@optimistic_locals, other.optimistic_locals),
        optimistic_ivars: join_optimistic_marks(@optimistic_ivars, other.optimistic_ivars),
        # UNION, the published-constant mark's direction: the mark only withholds the memoizing `||=`
        # reading, so keeping a site either arm holds is the wider answer.
        repeated_or_writes: join_repeated_or_writes(other),
        # Issue #1358 — the frame the body runs in, stamped at its entry like the nesting above, so both arms
        # of a merge inside one body carry the same one; `||` keeps it should either arm lack it, since dropping
        # it only loses the frame's resets.
        match_frame: @match_frame || other.match_frame,
        # Issue #1429 — the guard narrowings of globals and constants and their pre-guard records, and of instance
        # variables (#1446).
        **join_guard_narrowings(other, joined_globals, joined_ivars)
      )
    end

    def join_guard_narrowings(other, joined_globals, joined_ivars)
      joined_constants = join_constant_narrowings(other)
      joined = { global: joined_globals, ivar: joined_ivars, constant: joined_constants }
      { constant_narrowings: joined_constants, guard_records: join_guard_records(other, joined),
        bot_guard_classes: join_bot_guard_classes(other) }
    end

    # Issue #1446 — an entry both arms hold, with the classes of either: the joined receiver reads `bot` only where
    # both arms do. One only an arm holds is dropped, so a call on the joined `bot` reads as on an unknown one.
    def join_bot_guard_classes(other)
      mine = @bot_guard_classes
      theirs = other.bot_guard_classes
      return mine if mine.equal?(theirs)
      return EMPTY_BOT_GUARD_CLASSES if mine.empty? || theirs.empty?

      joined = mine.each_with_object({}) do |(key, names), acc|
        other_names = theirs[key]
        acc[key] = (names | other_names).freeze if other_names
      end
      joined.empty? ? EMPTY_BOT_GUARD_CLASSES : joined.freeze
    end

    # Issue #1429 — a constant reference both arms narrow reads the union; one only an arm narrows reads its resolved
    # type again, which the other arm reads too.
    def join_constant_narrowings(other)
      mine = @constant_narrowings
      theirs = other.constant_narrowings
      return mine if mine.equal?(theirs)
      return EMPTY_CONSTANT_NARROWINGS if mine.empty? || theirs.empty?

      joined = join_bindings(mine, theirs)
      joined.empty? ? EMPTY_CONSTANT_NARROWINGS : joined
    end

    # Issue #589 — intersect the struct fold-safe grants. Zero-alloc on the common path, where both arms
    # carry the same frozen set the body scan stamped.
    # A `nil` on EITHER side yields no grants. The field is keyword-defaulted to `EMPTY_FOLD_SAFE` and
    # threaded by `rebuild`, so `nil` should be unreachable — but the two sides are deliberately symmetric
    # rather than one arm trusting the other, because the asymmetric form kept every grant when the OTHER
    # side was nil, which is the one direction that can fold a stale value.
    def join_struct_fold_safe(other)
      mine = @struct_fold_safe_locals
      theirs = other.struct_fold_safe_locals
      return EMPTY_FOLD_SAFE if mine.nil? || theirs.nil?
      return mine if mine.equal?(theirs) || mine == theirs
      return EMPTY_FOLD_SAFE if mine.empty? || theirs.empty?

      intersected = mine & theirs
      intersected.empty? ? EMPTY_FOLD_SAFE : intersected.freeze
    end

    # ADR-82 WD1 — merge two branches' propagated origins (self wins on a name conflict; advisory metadata, so
    # a disagreement is harmless). Zero-alloc when either side is empty — the common case, keeping the join
    # hot-path cost negligible.
    def join_origins(mine, theirs)
      return mine if mine.equal?(theirs) || theirs.empty?
      return theirs if mine.empty?

      theirs.merge(mine).freeze
    end

    # Issue #286's mark tables join as {#join_origins} does, except for the miss answer a mark may carry (issue
    # #1302): a name both arms mark keeps its answer only when the arms agree on it. A name one arm marks keeps
    # that arm's answer, since a miss runs through that arm only.
    def join_optimistic_marks(mine, theirs)
      return mine if mine.equal?(theirs) || theirs.empty?
      return theirs if mine.empty?

      theirs.merge(mine) { |_name, their_mark, my_mark| Inference::OptimisticOrigin.join_bound_marks(my_mark, their_mark) }
            .freeze
    end

    # ADR-82 WD1 — rebinding drops any propagated origin for the name (the new value's provenance is set
    # afterward by `with_local_origin` when it is a `Dynamic` with a recorded cause). Zero-alloc when the name
    # carries no origin — the overwhelming common case, so this stays off the with_local hot-path budget.
    def drop_origin(origins, name)
      key = name.to_sym
      origins.key?(key) ? origins.reject { |k, _| k == key }.freeze : origins
    end

    # Two kinds of mark share this Set with opposite join semantics:
    #
    # - ADR-58 WD1 declaration-sourced optionality (`:ivar` / `:local`) joins by **intersection** — a nil is
    #   assumed a cross-method invariant only when BOTH branches agree its optionality is declaration-sourced.
    # - ADR-67 WD6b inferred-parameter taint (`:inferred_param`) joins by **union** — a local is a lower-bound
    #   value on the branch where it derives from an inferred parameter, so if EITHER branch taints it, a
    #   downstream use could observe the lower-bound value and firing on it is an FP (`x = param else x = 5;
    #   x.foo`). Intersecting would lose the taint at the merge and re-surface the false positive.
    #
    # Issue #1362 — a local both branches mark as copies of global seeds keeps its mark with the union of the globals
    # the two record, so a consumer compares against the writes to every one of them. A `(:local, name)` mark only
    # one branch backs with a record is dropped with it: that branch copies a global and the other an ivar, so no
    # comparison answers for the merge and it is flow-live.
    def join_declaration_sourced(other)
      mine = @declaration_sourced
      theirs = other.declaration_sourced
      return mine if mine.equal?(theirs)

      inferred = Set.new
      mine.each { |ref| inferred << ref if ref[0] == :inferred_param }
      theirs.each { |ref| inferred << ref if ref[0] == :inferred_param }
      intersected =
        if mine.empty? || theirs.empty?
          EMPTY_DECLARATION_SOURCED
        else
          join_copy_records(mine.select { |ref| ref[0] != :inferred_param && theirs.include?(ref) }, mine, theirs)
        end
      merged = inferred.merge(intersected)
      merged.empty? ? EMPTY_DECLARATION_SOURCED : merged.freeze
    end

    # `kept`, the refs both branches carry, with the `[:global_copy, …]` records rejoined ({#join_declaration_sourced}).
    def join_copy_records(kept, mine, theirs)
      mine_copies = global_copy_records(mine)
      theirs_copies = global_copy_records(theirs)
      return kept if mine_copies.empty? && theirs_copies.empty?

      joined = kept.reject { |ref| ref[0] == :global_copy }
      (mine_copies.keys | theirs_copies.keys).each do |name|
        if mine_copies.key?(name) && theirs_copies.key?(name) && joined.include?([:local, name])
          joined.concat(mine_copies[name] | theirs_copies[name])
        else
          joined.delete([:local, name])
        end
      end
      joined
    end

    def global_copy_records(refs)
      refs.each_with_object({}) { |ref, acc| (acc[ref[1]] ||= []) << ref if ref[0] == :global_copy }
    end

    def indexed_key(receiver_kind, receiver_name, key)
      IndexedKey.new(
        receiver_kind: receiver_kind.to_sym,
        receiver_name: receiver_name.to_sym,
        key: key
      )
    end

    def chain_key(receiver_kind, receiver_name, method_name)
      ChainKey.new(
        receiver_kind: receiver_kind.to_sym,
        receiver_name: receiver_name.to_sym,
        method_name: method_name.to_sym
      )
    end

    def drop_indexed_narrowings_for(receiver_kind, receiver_name)
      return @indexed_narrowings if @indexed_narrowings.empty?

      sym_kind = receiver_kind.to_sym
      sym_name = receiver_name.to_sym
      filtered = @indexed_narrowings.reject do |k, _|
        (k.receiver_kind == sym_kind && k.receiver_name == sym_name) || key_guard_rooted_at?(k.key, sym_kind, sym_name)
      end
      filtered.size == @indexed_narrowings.size ? @indexed_narrowings : filtered.freeze
    end

    # Issue #1703 — whether `key` is a `key?` guard's key that is the variable `kind`/`name`, or a chain read from it.
    def key_guard_rooted_at?(key, kind, name)
      return false unless key.is_a?(Inference::KeyPresenceGuard::KeyExpr)

      root = key.root
      root[0] == kind && root[1] == name
    end

    # ADR-58 WD1 — set/clear the declaration-sourced provenance mark.
    # Issue #667 — the #667 carrier's add/drop pair. Deliberately not reusing
    # {#add_declaration_sourced} / {#drop_declaration_sourced_for}: the two sets are joined by opposite
    # policies, so sharing the storage would make every future edit to either one a decision about both.
    def add_published_constant_sourced(kind, name)
      ref = [kind.to_sym, name.to_sym].freeze
      return @published_constant_sourced if @published_constant_sourced.include?(ref)

      (@published_constant_sourced.dup << ref).freeze
    end

    def drop_published_constant_sourced_for(kind, name)
      return @published_constant_sourced if @published_constant_sourced.empty?

      ref = [kind.to_sym, name.to_sym]
      return @published_constant_sourced unless @published_constant_sourced.include?(ref)

      (@published_constant_sourced - [ref]).freeze
    end

    def join_published_constant_sourced(other)
      mine = @published_constant_sourced
      theirs = other.published_constant_sourced
      return mine if mine.equal?(theirs) || theirs.empty?
      return theirs if mine.empty?

      (mine | theirs).freeze
    end

    def join_repeated_or_writes(other)
      mine = @repeated_or_writes
      theirs = other.repeated_or_writes
      return mine if mine.equal?(theirs) || theirs.empty?
      return theirs if mine.empty?

      mine.merge(theirs).freeze
    end

    def add_declaration_sourced(kind, name)
      ref = [kind.to_sym, name.to_sym]
      return @declaration_sourced if @declaration_sourced.include?(ref)

      (@declaration_sourced.dup << ref).freeze
    end

    def drop_declaration_sourced_for(kind, name)
      return @declaration_sourced if @declaration_sourced.empty?

      ref = [kind.to_sym, name.to_sym]
      return @declaration_sourced unless @declaration_sourced.include?(ref)

      dropped = @declaration_sourced.dup
      dropped.delete(ref)
      dropped.freeze
    end

    # The `(:local, name)` mark and, when it was there, the `[:global_copy, name, global]` records that only ever sit
    # beside it ({#with_global_copy_marks}).
    def drop_local_declaration_marks(name)
      dropped = drop_declaration_sourced_for(:local, name)
      return dropped if dropped.equal?(@declaration_sourced)

      name = name.to_sym
      return dropped unless dropped.any? { |ref| ref[0] == :global_copy && ref[1] == name }

      dropped.dup.delete_if { |ref| ref[0] == :global_copy && ref[1] == name }.freeze
    end

    def add_guard_record(key, pre_guard)
      return @guard_records if @guard_records.key?(key)

      @guard_records.merge(key => pre_guard).freeze
    end

    def drop_bot_guard_class(kind, name)
      return @bot_guard_classes if @bot_guard_classes.empty?

      key = [kind, kind == :constant ? name : name.to_sym]
      @bot_guard_classes.key?(key) ? @bot_guard_classes.except(key).freeze : @bot_guard_classes
    end

    def drop_guard_record(kind, name)
      return @guard_records if @guard_records.empty?

      key = [kind, name]
      @guard_records.key?(key) ? @guard_records.except(key).freeze : @guard_records
    end

    def drop_chain_narrowings_for(receiver_kind, receiver_name)
      return @method_chain_narrowings if @method_chain_narrowings.empty?

      sym_kind = receiver_kind.to_sym
      sym_name = receiver_name.to_sym
      filtered = @method_chain_narrowings.reject do |k, _|
        k.receiver_kind == sym_kind && k.receiver_name == sym_name
      end
      filtered.size == @method_chain_narrowings.size ? @method_chain_narrowings : filtered.freeze
    end
  end
end
