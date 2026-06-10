# frozen_string_literal: true

require_relative "type"
require_relative "environment"
require_relative "scope/discovery_index"
require_relative "analysis/fact_store"
require_relative "analysis/dependency_recorder"
require_relative "inference/expression_typer"
require_relative "inference/flow_tracer"
require_relative "inference/statement_evaluator"

module Rigor
  # Immutable analyzer scope: holds local-variable bindings and a reference
  # to the surrounding Environment. State changes return new scopes through
  # explicit transition methods (#with_local). The central query is
  # #type_of(node), the Rigor counterpart of PHPStan's
  # $scope->getType($node).
  #
  # See docs/internal-spec/inference-engine.md for the binding contract.
  # rubocop:disable Metrics/ClassLength,Metrics/ParameterLists
  class Scope
    attr_reader :environment, :locals, :fact_store, :self_type,
                :ivars, :cvars, :globals,
                :indexed_narrowings, :method_chain_narrowings,
                :source_path, :discovery

    # ADR-53 Track A — the seed-time discovery tables live on the
    # {DiscoveryIndex} the scope carries by a single reference; the
    # per-table readers stay on Scope so engine call sites and plugins
    # are unaffected by the extraction.
    def declared_types = @discovery.declared_types
    def class_ivars = @discovery.class_ivars
    def class_cvars = @discovery.class_cvars
    def program_globals = @discovery.program_globals
    def discovered_classes = @discovery.discovered_classes
    def in_source_constants = @discovery.in_source_constants
    def discovered_methods = @discovery.discovered_methods
    def discovered_def_nodes = @discovery.discovered_def_nodes
    def discovered_def_sources = @discovery.discovered_def_sources
    def discovered_method_visibilities = @discovery.discovered_method_visibilities
    def discovered_superclasses = @discovery.discovered_superclasses
    def discovered_includes = @discovery.discovered_includes
    def discovered_class_sources = @discovery.discovered_class_sources
    def data_member_layouts = @discovery.data_member_layouts

    # Narrowing key for an indexed read `receiver[key]` where both
    # the receiver and the key are stable enough to address. The
    # value of the map at this key is the narrowed type the next
    # read at the same address MUST observe.
    #
    # - `receiver_kind` ∈ `{:local, :ivar}` — the analyzer only
    #   tracks reads against a local or instance variable today.
    # - `receiver_name` is the variable's Symbol.
    # - `key` is the Ruby value of the literal index (Symbol /
    #   String / Integer). Non-literal keys (`params[field]`) are
    #   not recorded; they have no stable address.
    IndexedKey = Data.define(:receiver_kind, :receiver_name, :key)

    # Narrowing key for a no-arg / no-block method-call chain
    # `receiver.method_name` (a "single-hop" chain per A1 from the
    # ROADMAP § Future cycles slice). The value of the map at this
    # key is the narrowed type the next read of the same chain
    # MUST observe — typically the post-`is_a?(C)` narrowing
    # established on a predicate edge.
    #
    # - `receiver_kind` ∈ `{:local, :ivar}` — the analyzer only
    #   tracks chains rooted at a local or instance variable
    #   today (Law-of-Demeter-style single-hop).
    # - `receiver_name` is the root variable's Symbol.
    # - `method_name` is the no-arg method invoked on the root.
    #
    # Chains with arguments (`x.first(3)`), with a block
    # (`x.detect { ... }`), or with intermediate links
    # (`x.foo.bar`) are NOT recorded; each loses stability for
    # different reasons (args / block alter the call's return;
    # multi-hop loses the LoD guarantee).
    ChainKey = Data.define(:receiver_kind, :receiver_name, :method_name)

    EMPTY_VAR_BINDINGS = {}.freeze
    EMPTY_INDEXED_NARROWINGS = {}.freeze
    EMPTY_CHAIN_NARROWINGS = {}.freeze
    private_constant :EMPTY_VAR_BINDINGS, :EMPTY_INDEXED_NARROWINGS,
                     :EMPTY_CHAIN_NARROWINGS

    class << self
      def empty(environment: Environment.default, source_path: nil)
        new(environment: environment, locals: {}.freeze,
            fact_store: Analysis::FactStore.empty, source_path: source_path)
      end
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
      source_path: nil
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
      @source_path = source_path
      freeze
    end

    def local(name)
      @locals[name.to_sym]
    end

    def with_local(name, type)
      # `rigor trace` — the moment a local enters the scope.
      Inference::FlowTracer.bind(name, type) if Inference::FlowTracer.active?
      new_locals = @locals.merge(name.to_sym => type).freeze
      new_fact_store = fact_store.invalidate_target(Analysis::FactStore::Target.local(name))
      # Rebinding `name` invalidates every "after `receiver[key]
      # ||= default`" narrowing keyed on it — the slot at `name[*]`
      # is reachable through the old binding only, so the
      # next read against the new binding does not inherit the
      # earlier non-nil guarantee. The same logic applies to
      # method-chain narrowings: `x.last` after `x = something_new`
      # is a call on the new binding and any prior `is_a?`-driven
      # narrowing keyed on `(local, :x, :last)` no longer holds.
      new_indexed_narrowings = drop_indexed_narrowings_for(:local, name)
      new_chain_narrowings = drop_chain_narrowings_for(:local, name)
      rebuild(locals: new_locals, fact_store: new_fact_store,
              indexed_narrowings: new_indexed_narrowings,
              method_chain_narrowings: new_chain_narrowings)
    end

    def with_fact(fact)
      rebuild(fact_store: fact_store.with_fact(fact))
    end

    # Slice A-engine. Returns a scope with `self_type` set to `type`,
    # preserving locals and facts. `StatementEvaluator` injects this
    # at class-body and method-body boundaries; `ExpressionTyper`
    # consults it when typing `Prism::SelfNode` and implicit-self
    # `Prism::CallNode` receivers.
    def with_self_type(type)
      rebuild(self_type: type)
    end

    # ADR-11 per-call-site assertion gating prerequisite. The
    # analyzer's per-file boundary stamps the current source
    # file's path onto the seed scope; nested rebuilds carry
    # the value through so plugin hooks like
    # `flow_contribution_for` can resolve "which file does
    # this call site belong to?" without thread-locals.
    def with_source_path(path)
      rebuild(source_path: path)
    end

    # ADR-53 Track A — swaps the whole discovery index in one transition.
    # The canonical seeding path; the per-table `with_discovered_*` writers
    # below are shims over it and are queued for removal in slice A2.
    def with_discovery(index)
      rebuild(discovery: index)
    end

    # Slice A-declarations. Returns a scope that carries an
    # identity-comparing Hash of `Prism::Node => Rigor::Type`
    # overrides. `ExpressionTyper#type_of(node)` MUST consult
    # `declared_types[node]` before any other dispatch and
    # return the recorded type as-is when present. The table is
    # populated by `ScopeIndexer` for declaration-position
    # nodes (the `constant_path` of `Prism::ModuleNode` and
    # `Prism::ClassNode`) so a `module Foo` / `class Bar`
    # header types as `Singleton[<qualified path>]` instead of
    # falling through to `Dynamic[Top]`. The table is shared
    # by structural reference across every derived scope so
    # `with_local` / `with_fact` / `with_self_type` carry it
    # transparently.
    def with_declared_types(table)
      rebuild(discovery: @discovery.with(declared_types: table))
    end

    # Slice 7 phase 1 — instance/class/global variable bindings.
    # `ivar(name)` / `cvar(name)` / `global(name)` return the
    # type currently bound for the named variable, or `nil` when
    # the variable has not been written in the analyzed slice of
    # the program. The first cut tracks bindings only within a
    # single method body (each `def` enters with a fresh binding
    # map), so reads in other methods of the same class fall
    # through to `Dynamic[Top]`. Cross-method ivar/cvar inference
    # is a follow-up slice.
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
      rebuild(ivars: @ivars.merge(name.to_sym => type).freeze,
              indexed_narrowings: new_indexed_narrowings,
              method_chain_narrowings: new_chain_narrowings)
    end

    def with_cvar(name, type)
      rebuild(cvars: @cvars.merge(name.to_sym => type).freeze)
    end

    def with_global(name, type)
      rebuild(globals: @globals.merge(name.to_sym => type).freeze)
    end

    # Slice 7 phase 2 — class-level ivar accumulator. Keyed by
    # the qualified class name (e.g. `"Rigor::Scope"`); the
    # value is a `Hash[Symbol, Type::t]` of every ivar that
    # appears as a write target inside any def body of that
    # class. `StatementEvaluator#build_method_entry_scope`
    # seeds the method body's `ivars` map from this table so a
    # `def get; @x; end` reads the type written in a sibling
    # `def init; @x = 1; end`.
    #
    # `ScopeIndexer` populates the table once at index time
    # through a separate pre-pass over the program. The map is
    # frozen and shared by structural reference across every
    # derived scope.
    def class_ivars_for(class_name)
      return EMPTY_VAR_BINDINGS if class_name.nil?

      @discovery.class_ivars[class_name.to_s] || EMPTY_VAR_BINDINGS
    end

    def with_class_ivars(table)
      rebuild(discovery: @discovery.with(class_ivars: table))
    end

    # Slice 7 phase 6 — class-level cvar accumulator (same shape
    # as `class_ivars` but populated from `Prism::ClassVariableWriteNode`
    # writes, and seeded on BOTH instance and singleton method
    # bodies because Ruby cvars are visible from each).
    def class_cvars_for(class_name)
      return EMPTY_VAR_BINDINGS if class_name.nil?

      @discovery.class_cvars[class_name.to_s] || EMPTY_VAR_BINDINGS
    end

    def with_class_cvars(table)
      rebuild(discovery: @discovery.with(class_cvars: table))
    end

    # Slice 7 phase 6 — program-level globals accumulator.
    # Globals are process-wide in Ruby, so the analyzer carries a
    # single map (`Hash[Symbol, Type]`) keyed by the variable name
    # and seeded into every method body (instance and singleton)
    # plus the top-level program scope. `ScopeIndexer` populates
    # it from a single program-wide pre-pass.
    def with_program_globals(table)
      rebuild(discovery: @discovery.with(program_globals: table))
    end

    # Slice 7 phase 7 — in-source class discovery. Maps a
    # qualified class name (e.g. `"Account"`) to its
    # `Type::Singleton` so references to user-defined classes
    # in the analyzed files resolve through
    # `ExpressionTyper#resolve_constant_name` even when no RBS
    # decl exists. Populated once at index time by
    # `ScopeIndexer` from every `Prism::ClassNode` and
    # `Prism::ModuleNode` it walks.
    def with_discovered_classes(table)
      rebuild(discovery: @discovery.with(discovered_classes: table))
    end

    # Slice 7 phase 9 — in-source constant-value tracking.
    # Maps a qualified constant name (e.g. `"BUCKETS"` or
    # `"Rigor::Analysis::FactStore::BUCKETS"`) to the type of
    # the rvalue assigned at its `Prism::ConstantWriteNode` /
    # `Prism::ConstantPathWriteNode`. Populated by
    # `ScopeIndexer` once at index time. `ExpressionTyper#resolve_constant_name`
    # consults this map after class lookups so an in-source
    # constant assignment overrides any RBS-declared constant
    # of the same qualified name (matching Ruby's runtime
    # precedence: a constant defined in user code is the
    # authoritative value).
    def with_in_source_constants(table)
      rebuild(discovery: @discovery.with(in_source_constants: table))
    end

    # Slice 7 phase 12 — in-source method discovery. Maps a
    # qualified class name to a `Hash[Symbol, Symbol]` of
    # `method_name => :instance | :singleton`. Populated by
    # `ScopeIndexer` from every `Prism::DefNode` and recognised
    # `define_method` invocation inside class/module bodies. The
    # `rigor check` undefined-method and wrong-arity rules
    # consult this map to suppress diagnostics for methods the
    # user has defined dynamically, even when no RBS sig
    # describes them.
    def discovered_method?(class_name, method_name, kind)
      table = @discovery.discovered_methods[class_name.to_s]
      return false unless table

      table[method_name.to_sym] == kind
    end

    # ADR-34 § "Decision" — predicate identifying a toplevel-shaped
    # scope (no enclosing `class` / `module` body). True at the top
    # of a file AND inside a top-level `def` body (since toplevel
    # defs leave `self_type` nil per the existing scope-construction
    # contract, mirroring how ADR-24's `adoptable_self_call_result?`
    # also keys on `self_type.nil?` for the same context). Used by
    # `CheckRules#unresolved_toplevel_diagnostic` to gate the
    # `call.unresolved-toplevel` rule so it fires only outside
    # class / module bodies, where Rails-DSL metaprogramming
    # leniency (ADR-24 WD3 → WD4) does not apply.
    def toplevel?
      @self_type.nil?
    end

    def with_discovered_methods(table)
      rebuild(discovery: @discovery.with(discovered_methods: table))
    end

    # v0.0.2 #5 — per-class table mapping
    # `method_name (Symbol) → Prism::DefNode`. Populated by
    # `ScopeIndexer` alongside `discovered_methods` for
    # instance-side defs only (singleton-side and
    # `define_method`-introduced methods do not contribute a
    # static body the engine can re-type). Consumed by
    # `ExpressionTyper` to do inter-procedural return-type
    # inference when the receiver class is user-defined and
    # has no RBS sig.
    def user_def_for(class_name, method_name)
      table = @discovery.discovered_def_nodes[class_name.to_s]
      node = table && table[method_name.to_sym]
      record_cross_file_method(class_name, method_name, node) if Analysis::DependencyRecorder.active?
      node
    end

    # ADR-46 slice 1 — note the cross-file dependency this resolution
    # creates: the file defining `class_name#method_name` (the consumer's
    # analysis reads its body via `infer_user_method_return`), or, when
    # unresolved, a negative edge so a later definition re-checks the
    # consumer. Gated on the recorder being active — no-op on a normal run.
    def record_cross_file_method(class_name, method_name, node)
      if node
        # ADR-46 slice 4 — pass the symbol so the recorder tracks this as a
        # method-call (symbol-granularity) edge rather than a file-level edge.
        Analysis::DependencyRecorder.read_site(
          @discovery.discovered_def_sources.dig(class_name.to_s, method_name.to_sym),
          "#{class_name}##{method_name}"
        )
      else
        Analysis::DependencyRecorder.read_missing(:method, "#{class_name}##{method_name}")
      end
    end
    private :record_cross_file_method

    # v0.0.3 A — top-level def lookup for implicit-self
    # calls. Returns the `Prism::DefNode` for a top-level
    # (or DSL-block-nested, outside any class body) `def
    # <method_name>` in the file, or nil. The sentinel key
    # is owned by `Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY`;
    # consumers should treat its presence as an opaque
    # implementation detail and go through this accessor.
    def top_level_def_for(method_name)
      table = @discovery.discovered_def_nodes[Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY]
      node = table && table[method_name.to_sym]
      record_cross_file_toplevel(method_name, node) if Analysis::DependencyRecorder.active?
      node
    end

    # ADR-46 slice 3 — a top-level (`def helper` outside any class) call has
    # NO class ancestry to walk, so unlike {#user_def_for} a miss here records
    # no positive ancestry edge that would re-check the consumer when the
    # method later appears. Record the cross-file edge explicitly: the file
    # defining the top-level method (symbol-granularity, so a body / removal
    # edit re-checks the caller), or, on a miss, a negative `toplevel:` edge
    # so a later top-level definition re-checks this consumer (the
    # `call.unresolved-toplevel` stale-diagnostic gap).
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

    def with_discovered_def_nodes(table)
      rebuild(discovery: @discovery.with(discovered_def_nodes: table))
    end

    # Companion to {#user_def_for}: returns the `"path:line"` where
    # the project defines `class_name#method_name` (instance-side),
    # or nil. Populated only by the cross-file project pre-pass
    # ({Inference::ScopeIndexer.discovered_def_index_for_paths}) — a
    # `Prism::Location` hides its source file, so the site is recorded
    # at scan time. `CheckRules#undefined_method_diagnostic` consults
    # this to name the defining file when a project monkey-patch on a
    # core/stdlib/gem class is called cross-file, so the diagnostic
    # can point at `pre_eval:` (ADR-17) instead of reading as a bare
    # unresolved call.
    def user_def_site_for(class_name, method_name)
      table = @discovery.discovered_def_sources[class_name.to_s]
      return nil unless table

      table[method_name.to_sym]
    end

    def with_discovered_def_sources(table)
      rebuild(discovery: @discovery.with(discovered_def_sources: table))
    end

    # ADR-24 slice 2 — per-class table mapping a fully
    # qualified user-class name to its superclass name AS
    # WRITTEN at the `class Foo < Bar` declaration (`"Bar"`,
    # possibly a qualified `"A::B"`). Populated by `ScopeIndexer`
    # — per-file plus the cross-file project pre-pass — and
    # consumed by `ExpressionTyper#try_user_method_inference`
    # to walk the superclass chain when an implicit-self call
    # does not resolve against the enclosing class's own defs.
    # The as-written name is resolved to a qualified class at
    # walk time against the call's lexical nesting.
    def superclass_of(class_name)
      record_class_dependency(class_name) if Analysis::DependencyRecorder.active?
      @discovery.discovered_superclasses[class_name.to_s]
    end

    def with_discovered_superclasses(table)
      rebuild(discovery: @discovery.with(discovered_superclasses: table))
    end

    # ADR-48 — per-class table mapping a fully qualified class name to its
    # ordered `Data.define` / `Struct.new` member-name list. Populated by
    # `ScopeIndexer` for both the constant-assigned form
    # (`Point = Data.define(:x, :y)`) and the named-subclass form
    # (`class Point < Data.define(:x, :y)`). Consumed by
    # {Inference::MethodDispatcher::DataFolding} so `Point.new(...)` on a
    # `Singleton[Point]` receiver materialises a precise member instance.
    # Returns nil when the class has no recorded layout.
    def data_member_layout(class_name)
      layout = @discovery.data_member_layouts[class_name.to_s]
      # Record the ancestry dependency only on a hit — DataFolding consults
      # this for every `Singleton[*].new`, and a miss (the common case: an
      # ordinary class) must not manufacture a spurious cross-file edge.
      record_class_dependency(class_name) if layout && Analysis::DependencyRecorder.active?
      layout
    end

    def with_data_member_layouts(table)
      rebuild(discovery: @discovery.with(data_member_layouts: table))
    end

    # ADR-24 slice 2 — per-class/module table mapping a fully
    # qualified user class or module to the list of module
    # names it `include`s / `prepend`s, AS WRITTEN at the
    # mixin call. Populated by `ScopeIndexer` (per-file plus
    # the cross-file pre-pass) and consumed by
    # `ExpressionTyper#resolve_user_def_through_ancestors` so an
    # implicit-self call resolves against an included module's
    # `def`s, not just the superclass chain. As-written names
    # are resolved to qualified classes at walk time.
    def includes_of(class_name)
      record_class_dependency(class_name) if Analysis::DependencyRecorder.active?
      @discovery.discovered_includes[class_name.to_s] || []
    end

    def with_discovered_includes(table)
      rebuild(discovery: @discovery.with(discovered_includes: table))
    end

    # ADR-46 slice 1 — per-class table mapping a fully qualified user
    # class/module name to the set of `"path:line"` sites that declare,
    # reopen, set the superclass of, or `include` into it. Populated only
    # by the cross-file project pre-pass
    # ({Inference::ScopeIndexer.discovered_def_index_for_paths}) and
    # consumed by {#superclass_of} / {#includes_of} when dependency
    # recording is active: resolving a class's ancestry edge records every
    # file that contributes to that class's declaration shape, so a later
    # edit to any of them re-checks the consumer. Over-records by design
    # (a superclass read also pulls in the include-declaring files) — the
    # conservative direction ADR-46 mandates.
    def with_discovered_class_sources(table)
      rebuild(discovery: @discovery.with(discovered_class_sources: table))
    end

    # Records, for a resolved cross-class ancestry read, every file that
    # declares `class_name` (its declaration / reopening / superclass /
    # include sites). No-op when the class is not a project class (core /
    # stdlib / gem names never appear in the source map). Gated by the
    # caller on the recorder being active.
    def record_class_dependency(class_name)
      sites = @discovery.discovered_class_sources[class_name.to_s]
      return if sites.nil?

      sites.each { |site| Analysis::DependencyRecorder.read_site(site) }
    end
    private :record_class_dependency

    # v0.1.2 — per-class table mapping `method_name (Symbol) →
    # :public | :private | :protected`. Populated by
    # `ScopeIndexer` for every `def` it sees inside a class
    # body, with the visibility taken from the surrounding
    # `private` / `protected` / `public` modifier state plus
    # any post-hoc `private :name, ...` named-argument calls.
    # Consumed by the `def.method-visibility-mismatch` rule
    # so explicit-non-self calls to a private method surface
    # a diagnostic.
    def discovered_method_visibility(class_name, method_name)
      table = @discovery.discovered_method_visibilities[class_name.to_s]
      return nil unless table

      table[method_name.to_sym]
    end

    def with_discovered_method_visibilities(table)
      rebuild(discovery: @discovery.with(discovered_method_visibilities: table))
    end

    # Closes the "`params[:f] ||= []; params[:f] << x`" precision
    # gap (ROADMAP § Type-language / engine — indexed-collection
    # narrowing through `Hash[k] ||= default`). After
    # `receiver[key] ||= default`, the next read at `receiver[key]`
    # is known non-nil; recording the post-`||=` type keyed on
    # `(receiver_kind, receiver_name, literal_key)` lets the
    # ExpressionTyper's `[]` dispatch hand back the narrowed
    # type. Receiver-rebind and `[]=`/mutator invalidation rules
    # are documented at the call sites in
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

    # Closes the "stable receiver method-chain narrowing" gap
    # (ROADMAP § Future cycles / Type-language / engine —
    # "Method-call receiver narrowing across stable receivers";
    # 2026-05-28 Redmine survey). After `if x.last.is_a?(Array)`
    # the dominated body's `x.last` reads MUST observe the
    # truthy-narrowed type; the same chain reaching the falsey
    # edge observes the negative narrowing.
    #
    # Address shape mirrors {.indexed_narrowing}: stable root
    # variable + no-arg single-hop method name. See
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

    # Statement-level evaluation: returns the pair `[type, scope']`
    # where `type` is what the node produces and `scope'` is the
    # scope observable after the node has run. The receiver scope is
    # never mutated. See {Rigor::Inference::StatementEvaluator} for
    # the catalogue of nodes that thread scope; everything else
    # defers to {#type_of} and returns the receiver scope unchanged.
    def evaluate(node, tracer: nil)
      Inference::StatementEvaluator.new(scope: self, tracer: tracer).evaluate(node)
    end

    # Joins this scope with another at a control-flow merge point. The
    # joined scope is bound to every local that BOTH branches bind, with
    # the type widened to the union of both sides. Names bound in only
    # one branch are dropped from the joined scope; the eventual
    # statement-level evaluator (Slice 3 phase 2) is responsible for
    # nil-injecting half-bound names where the language semantics demand
    # it. The two scopes MUST share the same Environment.
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
        @method_chain_narrowings == other.method_chain_narrowings
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
      source_path: @source_path
    )
      self.class.new(
        environment: environment, locals: locals,
        fact_store: fact_store, self_type: self_type,
        ivars: ivars, cvars: cvars, globals: globals,
        discovery: discovery,
        indexed_narrowings: indexed_narrowings,
        method_chain_narrowings: method_chain_narrowings,
        source_path: source_path
      )
    end

    def join_bindings(left, right)
      # Keys present in both, unioned. Iterating `left` and probing
      # `right.key?` yields the same keys in the same order as the prior
      # `(left.keys & right.keys)` while avoiding the two key arrays and
      # the intersection array — this is the control-flow join, run at
      # every branch merge, and was a top allocation site (~75% of
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
        source_path: source_path
      )
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
