# frozen_string_literal: true

require_relative "type"
require_relative "environment"
require_relative "scope/discovery_index"
require_relative "analysis/fact_store"
require_relative "analysis/dependency_recorder"
require_relative "inference/expression_typer"
require_relative "inference/flow_tracer"
require_relative "inference/statement_evaluator"
require_relative "inference/def_node_resolver"

module Rigor
  # Immutable analyzer scope: holds local-variable bindings and a reference to the surrounding Environment. State
  # changes return new scopes through explicit transition methods (#with_local). The central query is
  # #type_of(node), the Rigor counterpart of PHPStan's $scope->getType($node).
  #
  # See docs/internal-spec/inference-engine.md for the binding contract.
  # rubocop:disable Metrics/ClassLength,Metrics/ParameterLists
  class Scope
    attr_reader :environment, :locals, :fact_store, :self_type,
                :ivars, :cvars, :globals,
                :indexed_narrowings, :method_chain_narrowings,
                :declaration_sourced,
                :source_path, :discovery, :struct_fold_safe_locals,
                :opaque_block_self,
                :dynamic_origins, :local_origins, :ivar_origins,
                :void_origins,
                :optimistic_origins, :optimistic_locals, :optimistic_ivars

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
    def discovered_superclasses = @discovery.discovered_superclasses
    def discovered_includes = @discovery.discovered_includes
    def discovered_class_sources = @discovery.discovered_class_sources
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
    #   (`params[field]`) are not recorded; they have no stable address.
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
    private_constant :EMPTY_VAR_BINDINGS, :EMPTY_INDEXED_NARROWINGS,
                     :EMPTY_CHAIN_NARROWINGS, :EMPTY_DECLARATION_SOURCED,
                     :EMPTY_FOLD_SAFE, :EMPTY_ORIGINS

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

    def initialize(
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
      source_path: nil,
      struct_fold_safe_locals: EMPTY_FOLD_SAFE,
      opaque_block_self: false,
      dynamic_origins: {}.compare_by_identity,
      local_origins: EMPTY_ORIGINS,
      ivar_origins: EMPTY_ORIGINS,
      void_origins: {}.compare_by_identity,
      optimistic_origins: {}.compare_by_identity,
      optimistic_locals: EMPTY_ORIGINS,
      optimistic_ivars: EMPTY_ORIGINS
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
      @source_path = source_path
      @struct_fold_safe_locals = struct_fold_safe_locals
      @opaque_block_self = opaque_block_self
      @dynamic_origins = dynamic_origins
      @local_origins = local_origins
      @ivar_origins = ivar_origins
      @void_origins = void_origins
      @optimistic_origins = optimistic_origins
      @optimistic_locals = optimistic_locals
      @optimistic_ivars = optimistic_ivars
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

    def optimistic_local(name) = @optimistic_locals[name.to_sym]
    def optimistic_ivar(name) = @optimistic_ivars[name.to_sym]

    def with_optimistic_local(name, cause)
      return self if cause.nil?

      rebuild(optimistic_locals: @optimistic_locals.merge(name.to_sym => cause).freeze)
    end

    def with_optimistic_ivar(name, cause)
      return self if cause.nil?

      rebuild(optimistic_ivars: @optimistic_ivars.merge(name.to_sym => cause).freeze)
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
              declaration_sourced: drop_declaration_sourced_for(:local, name),
              local_origins: drop_origin(@local_origins, name),
              optimistic_locals: drop_origin(@optimistic_locals, name))
    end

    def with_fact(fact)
      rebuild(fact_store: fact_store.with_fact(fact))
    end

    # Slice A-engine. Returns a scope with `self_type` set to `type`, preserving locals and facts.
    # `StatementEvaluator` injects this at class-body and method-body boundaries; `ExpressionTyper` consults it
    # when typing `Prism::SelfNode` and implicit-self `Prism::CallNode` receivers.
    def with_self_type(type)
      rebuild(self_type: type)
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
      new_indexed_narrowings = drop_indexed_narrowings_for(:ivar, name)
      new_chain_narrowings = drop_chain_narrowings_for(:ivar, name)
      # ADR-58 WD1 — a method-local ivar write or narrowing is flow-live: drop any declaration-sourced mark so
      # subsequent reads of `@name` observe flow-live provenance and fire as before. The seed path uses
      # `seed_declaration_sourced_ivar` to (re-)establish the mark.
      rebuild(ivars: @ivars.merge(name.to_sym => type).freeze,
              indexed_narrowings: new_indexed_narrowings,
              method_chain_narrowings: new_chain_narrowings,
              declaration_sourced: drop_declaration_sourced_for(:ivar, name),
              ivar_origins: drop_origin(@ivar_origins, name),
              optimistic_ivars: drop_origin(@optimistic_ivars, name))
    end

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

    # ADR-58 WD1 — true when `(kind, name)`'s binding optionality is purely declaration-sourced (no flow-live
    # write/narrowing has touched it).
    def declaration_sourced?(kind, name)
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

    def with_global(name, type)
      rebuild(globals: @globals.merge(name.to_sym => type).freeze)
    end

    # Regex match-data globals (`$~`, `$&`, `$1..$9`, the pre/post-match and last-paren back-references). Narrowed
    # on a successful-`=~` / `case`-`when` match edge (see `Narrowing#regex_match_predicate_scopes`); any
    # subsequent method call could run another match and rebind every one of them, so `eval_call` forgets the
    # narrowed facts here. Always safe — only drops facts, so a subsequent read falls back to the default
    # `String | nil`. Program-level `$GLOBAL = ...` seeds use other names and are untouched.
    MATCH_DATA_GLOBALS = %i[$~ $& $` $' $+ $1 $2 $3 $4 $5 $6 $7 $8 $9].freeze
    private_constant :MATCH_DATA_GLOBALS

    def forget_match_globals
      return self unless @globals.keys.any? { |k| MATCH_DATA_GLOBALS.include?(k) }

      rebuild(globals: @globals.except(*MATCH_DATA_GLOBALS).freeze)
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

    def same_file_top_level_def?(method_name)
      key = Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY
      site = discovered_def_sources.dig(key, method_name.to_sym)
      return true if site.nil? || @source_path.nil?

      File.expand_path(site.sub(/:\d+\z/, "")) == File.expand_path(@source_path)
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
    # module names it `include`s / `prepend`s, AS WRITTEN at the mixin call. Populated by `ScopeIndexer` (per-file
    # plus the cross-file pre-pass) and consumed by `ExpressionTyper#resolve_user_def_through_ancestors` so an
    # implicit-self call resolves against an included module's `def`s, not just the superclass chain. As-written
    # names are resolved to qualified classes at walk time.
    def includes_of(class_name)
      record_class_dependency(class_name) if Analysis::DependencyRecorder.active?
      @discovery.discovered_includes[class_name.to_s] || []
    end

    # Records, for a resolved cross-class ancestry read, every file that declares `class_name` (its declaration /
    # reopening / superclass / include sites). The `discovered_class_sources` table it reads is populated only by
    # the cross-file project pre-pass ({Inference::ScopeIndexer.discovered_def_index_for_paths}) and only when
    # dependency recording is active. No-op when the class is not a project class (core / stdlib / gem names
    # never appear in the source map). Gated by the caller on the recorder being active.
    def record_class_dependency(class_name)
      sites = @discovery.discovered_class_sources[class_name.to_s]
      return if sites.nil?

      sites.each { |site| Analysis::DependencyRecorder.read_site(site) }
    end
    private :record_class_dependency

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
      joined_globals = join_bindings(globals, other.globals)
      build_joined_scope(joined_locals, joined_ivars, joined_cvars, joined_globals, other)
    end

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
        @declaration_sourced == other.declaration_sourced
    end
    alias eql? ==

    def hash
      [Scope, environment.object_id, @locals, fact_store, self_type, @ivars, @cvars, @globals].hash
    end

    private

    def rebuild(
      locals: @locals, fact_store: @fact_store, self_type: @self_type,
      ivars: @ivars, cvars: @cvars, globals: @globals,
      discovery: @discovery,
      indexed_narrowings: @indexed_narrowings,
      method_chain_narrowings: @method_chain_narrowings,
      declaration_sourced: @declaration_sourced,
      source_path: @source_path,
      struct_fold_safe_locals: @struct_fold_safe_locals,
      opaque_block_self: @opaque_block_self,
      dynamic_origins: @dynamic_origins,
      local_origins: @local_origins,
      ivar_origins: @ivar_origins,
      void_origins: @void_origins,
      optimistic_origins: @optimistic_origins,
      optimistic_locals: @optimistic_locals,
      optimistic_ivars: @optimistic_ivars
    )
      self.class.new(
        environment: environment, locals: locals,
        fact_store: fact_store, self_type: self_type,
        ivars: ivars, cvars: cvars, globals: globals,
        discovery: discovery,
        indexed_narrowings: indexed_narrowings,
        method_chain_narrowings: method_chain_narrowings,
        declaration_sourced: declaration_sourced,
        source_path: source_path,
        struct_fold_safe_locals: struct_fold_safe_locals,
        opaque_block_self: opaque_block_self,
        dynamic_origins: dynamic_origins,
        local_origins: local_origins,
        ivar_origins: ivar_origins,
        void_origins: void_origins,
        optimistic_origins: optimistic_origins,
        optimistic_locals: optimistic_locals,
        optimistic_ivars: optimistic_ivars
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
        environment: environment,
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
        source_path: source_path,
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
        dynamic_origins: @dynamic_origins,
        local_origins: join_origins(@local_origins, other.local_origins),
        ivar_origins: join_origins(@ivar_origins, other.ivar_origins),
        void_origins: @void_origins,
        optimistic_origins: @optimistic_origins,
        optimistic_locals: join_origins(@optimistic_locals, other.optimistic_locals),
        optimistic_ivars: join_origins(@optimistic_ivars, other.optimistic_ivars)
      )
    end

    # Issue #589 — intersect the struct fold-safe grants. Zero-alloc on the common path, where both arms
    # carry the same frozen set the body scan stamped.
    def join_struct_fold_safe(other)
      mine = @struct_fold_safe_locals
      theirs = other.struct_fold_safe_locals
      return mine if mine.equal?(theirs) || theirs.nil?
      return EMPTY_FOLD_SAFE if mine.nil? || mine.empty? || theirs.empty?
      return mine if mine == theirs

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
          mine.select { |ref| ref[0] != :inferred_param && theirs.include?(ref) }
        end
      merged = inferred.merge(intersected)
      merged.empty? ? EMPTY_DECLARATION_SOURCED : merged.freeze
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
        k.receiver_kind == sym_kind && k.receiver_name == sym_name
      end
      filtered.size == @indexed_narrowings.size ? @indexed_narrowings : filtered.freeze
    end

    # ADR-58 WD1 — set/clear the declaration-sourced provenance mark.
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
  # rubocop:enable Metrics/ClassLength,Metrics/ParameterLists
end
