# frozen_string_literal: true

require_relative "type"
require_relative "analysis/dependency_recorder"

module Rigor
  # Read-side facade over Rigor's three reflection sources:
  #
  # 1. **`Rigor::Environment::ClassRegistry`** — Ruby `Class` / `Module` objects (Integer,
  #    Float, Set, Pathname, …) registered at boot. Static; never changes during a `rigor
  #    check` run.
  # 2. **`Rigor::Environment::RbsLoader`** — RBS-side declarations (instance / singleton
  #    methods, class hierarchy, constants). Loaded on demand from the project's `sig/`
  #    directory + the bundled stdlib RBS.
  # 3. **`Rigor::Scope` discovered facts** — source-side discoveries produced by
  #    `Rigor::Inference::ScopeIndexer` (user-defined classes / modules, in-source
  #    constants, discovered method nodes, class ivar / cvar declarations).
  #
  # This module is the **stable read shape** the plugin API is designed against (ADR-2,
  # `docs/adr/2-extension-api.md`).
  #
  # The facade is **read-only and additive**. Existing call sites that read directly from
  # `Rigor::Scope` or `Rigor::Environment::RbsLoader` continue to work unchanged; they
  # migrate to the facade at their own pace. The facade performs no caching beyond what the
  # underlying sources already provide.
  #
  # ## Public surface (v0.0.7 first pass)
  #
  # - {.class_known?} — does any source recognise this class / module name?
  # - {.class_ordering} — `:equal` / `:subclass` / `:superclass` / `:disjoint` / `:unknown`
  #   ordering between two class names.
  # - {.nominal_for_name} — `Rigor::Type::Nominal` for the class name, joining registry + RBS
  #   lookups.
  # - {.singleton_for_name} — `Rigor::Type::Singleton` for the class name's class object.
  # - {.constant_type_for} — type of a constant (joins in-source constants and RBS-side
  #   constants).
  # - {.instance_method_definition} / {.singleton_method_definition} — RBS-side
  #   `RBS::Definition::Method` for the method, or `nil` when the method is not declared in
  #   RBS. Source-side discovered methods are exposed through {.discovered_method?} below
  #   until the unified `MethodDefinition` carrier ships.
  # - {.discovered_class?} / {.discovered_method?} — has the ScopeIndexer pass recorded the
  #   class / method as user-defined in the analyzed sources?
  #
  # The provenance side of the API (which source family contributed each fact) is explicitly
  # out of scope for the v0.0.7 first pass; v0.1.0's plugin API added it as a separate
  # concern.
  module Reflection
    # #354 — thread-local slot for the per-run ancestor-scope memo. See {.ancestor_constant_scopes}.
    ANCESTOR_SCOPES_KEY = :__rigor_ancestor_constant_scopes__
    private_constant :ANCESTOR_SCOPES_KEY

    module_function

    def class_known?(class_name, scope: Scope.empty)
      return true if scope.discovered_classes.key?(class_name.to_s)

      scope.environment.class_known?(class_name)
    end

    # RBS-only variant of {.class_known?}. Use when the caller needs to know specifically
    # whether RBS has a definition for the class, independent of any source-discovered `class
    # Foo; end` declarations. The diagnostic-rule code paths that walk RBS method tables to
    # decide whether to flag a missing method use this variant; otherwise the
    # source-discovered class would suppress the rule even when no RBS sig actually proves
    # the method exists.
    #
    # The kwarg accepts either `scope:` or `environment:`. The latter is for call sites that
    # don't carry a `Scope` (most are bottom-half dispatcher code paths called with only an
    # environment).
    def rbs_class_known?(class_name, scope: nil, environment: nil)
      loader = rbs_loader_for(scope, environment)
      return false if loader.nil?

      loader.class_known?(class_name)
    end

    # Issue #735 — true when the class's RBS declaration is the PROJECT's own (a file under
    # `signature_paths:`) rather than bundled core / stdlib / gem RBS. The two carry different authority:
    # a bundled signature describes a class the project does not own, so a project `def` on it is the
    # ADR-17 monkey-patch the analyzer reports; a project sidecar describes the very source being
    # analysed, and a `def` in another of the project's files is that class's own definition.
    #
    # False whenever the question cannot be answered (no loader, no environment, an environment cached
    # before #725 preserved buffer names), which is the pre-#735 reading in every case.
    def project_declared_class?(class_name, scope: nil, environment: nil)
      loader = rbs_loader_for(scope, environment)
      return false if loader.nil?

      loader.project_declared_class?(class_name)
    end

    # @rbs return: Symbol -- One of `:equal`, `:subclass`, `:superclass`, `:disjoint`, `:unknown`.
    def class_ordering(lhs, rhs, scope: Scope.empty)
      scope.environment.class_ordering(lhs, rhs)
    end

    # nil when no source knows the class.
    def nominal_for_name(class_name, scope: Scope.empty)
      scope.environment.nominal_for_name(class_name)
    end

    # nil when no source knows the class.
    def singleton_for_name(class_name, scope: Scope.empty)
      scope.environment.singleton_for_name(class_name)
    end

    # Joins in-source constants (recorded by `ScopeIndexer`) and RBS-side constants.
    # In-source wins on collision because the user's source is the authoritative declaration.
    #
    # This is the flat lookup keyed on the literal `constant_name`. Callers that need Ruby's
    # lexical constant resolution (walking the enclosing class path, and folding in registry
    # classes / source-discovered classes as `Singleton` / class types) use
    # {.resolve_constant_type} instead.
    def constant_type_for(constant_name, scope: Scope.empty)
      key = constant_name.to_s
      in_source = scope.in_source_constants[key]
      return in_source if in_source

      scope.environment.constant_for_name(constant_name)
    end

    # Resolves a constant *reference* to its type through Ruby's lexical constant lookup: the
    # most-qualified candidate first (the enclosing class path joined to `name`), then
    # progressively less-qualified, then the bare `name`. Each candidate consults, in order,
    # the class registry (yielding a `Singleton[C]`), source-discovered classes, in-source
    # value constants, and finally RBS-side constants — in-source value constants winning over
    # RBS because the user's source is authoritative for its own constants. Returns the matched
    # `Rigor::Type`, or nil when no source knows the constant.
    #
    # `rooted:` reports that the reference was written with a leading `::` (`::Foo`,
    # `::Foo::Bar`). Ruby's absolute form names the TOP-LEVEL constant unconditionally, so the
    # lexical ladder (steps 1 and 2) MUST be skipped and only the bare candidate consulted. The
    # name itself stays un-rooted — every discovered-constant table is keyed that way — so the
    # marker travels beside it rather than inside it (#614). When no top-level constant answers,
    # the result is nil exactly as for an unknown constant: a lexically nearer shadow is never the
    # answer to `::Foo`, and falling back to it was the bug (`::Rails` inside `module MyApp` typed
    # as `MyApp::Rails`).
    #
    # This is the shared owner of the lexical-constant resolution: `Inference::ExpressionTyper`
    # reads it to type a constant read, and `Inference::Narrowing` reads it to recognise a
    # value-pinned `Constant[Regexp]` match-predicate operand.
    def resolve_constant_type(name, scope: Scope.empty, rooted: false)
      # Issue #644 — the ADR-46 name edge, recorded ONCE PER REFERENCE and BEFORE the ladder, so it does not
      # depend on which resolver answers. A reference that resolves through RBS (`Math::PI`) or through the
      # class registry is exactly as dependent on the project's constant write set as one that resolves
      # through `in_source_constants`: a project file that later assigns the name wins over the RBS answer,
      # and without this edge the reader keeps serving the pre-assignment type. That staleness is NEW with
      # the cross-file publication — before it, a project value write never won at a reader, so nothing could
      # go stale. Over-recording is ADR-46's safe direction.
      record_constant_reference(name) if Analysis::DependencyRecorder.active?
      return constant_type_at(name, scope) if rooted
      # Issue #716 — a body whose `Module.nesting` was RECORDED EMPTY is definitively top level, and Ruby
      # resolves its constants there no matter which namespace calls it. Steps 1 and 2 both derive from the
      # caller and are both wrong for it, so it takes its own ladder.
      return toplevel_first_constant_type(name, scope) if recorded_toplevel_nesting?(scope)

      # Step 1 — `Module.nesting`, innermost first. Each entry contributes only its OWN constants.
      #
      # Step 2 (#354) — the ancestors of the innermost cresting scope, which Ruby consults BEFORE
      # falling back to the top level. Skipping this step did not merely lose a resolution: when the
      # same name also exists at top level, step 3 answered a lookup Ruby gives to the ancestor, so
      # `KEY` inside `class Sub < Base` typed as the top-level constant rather than `Base::KEY` — a
      # wrong type on correct code, which outranks any worst-case reading (AGENTS.md
      # § "Implementation Guidelines"). Only project ancestors are walked; an RBS-known superclass
      # contributes no name here (see {.ancestor_constant_scopes}).
      #
      # Step 3 — the bare name (top level).
      first_constant_hit(lexical_nesting_chain(scope), name, scope) ||
        ancestor_constant_type(name, scope, enclosing_class_path(scope)) ||
        constant_type_at(name, scope)
    end

    # The first candidate `<entry>::<name>` any source knows, walking `entries` in order, or nil. The one
    # place a qualifying prefix is joined to a name, so every rung of the ladder consults its candidates
    # identically.
    def first_constant_hit(entries, name, scope)
      entries.each do |entry|
        hit = constant_type_at("#{entry}::#{name}", scope)
        return hit if hit
      end
      nil
    end
    private_class_method :first_constant_hit

    # Step 2's rung on its own: nil when there is no enclosing class path to take ancestors of.
    def ancestor_constant_type(name, scope, prefix)
      return nil if prefix.nil? || prefix.empty?

      first_constant_hit(ancestor_constant_scopes(prefix, scope), name, scope)
    end
    private_class_method :ancestor_constant_type

    # Issue #716 — whether the scope carries a RECORDED empty `Module.nesting`, which is the declaration
    # walk's positive statement that the body is written at the top level (`Inference::ScopeIndexer#
    # walk_def_nestings`). Distinct from `nil`, which still means "no declaration walk built this scope" and
    # keeps the peel ({.lexical_nesting_chain}); the two are only distinguishable because the table is
    # populated by that walk alone.
    def recorded_toplevel_nesting?(scope) = scope.lexical_nesting.is_a?(Array) && scope.lexical_nesting.empty?
    private_class_method :recorded_toplevel_nesting?

    # Issue #716 — the ladder for a top-level body: the top level FIRST, then the caller-derived rungs
    # unchanged. The candidate SET is exactly what {.resolve_constant_type}'s three steps consult for the
    # same scope — only the order moves — so no read that resolves today stops resolving, and any read where
    # the two disagree is one where the top level is Ruby's answer and the caller's namespace never was.
    #
    # Keeping the caller-derived rungs at all is deliberate and unsound against Ruby: they cover reads whose
    # name exists ONLY under some namespace, where Ruby raises `NameError` (486 such reads on gitlab, 33 on
    # dependabot-core — `docs/notes/20260905-toplevel-def-cref-movable-sites.md`). Rigor reports nothing
    # about them either way, so retracting them would trade a silent wrong answer for a silent absent one at
    # no gain. Making them FIRE is a separate question with its own false-positive budget.
    def toplevel_first_constant_type(name, scope)
      constant_type_at(name, scope) || caller_derived_constant_type(name, scope)
    end
    private_class_method :toplevel_first_constant_type

    # The peel and its ancestors — {.resolve_constant_type}'s steps 1 and 2 as they answer for a scope with
    # no recorded chain, factored out so the top-level ladder above can consult them BELOW the top level
    # instead of above it.
    def caller_derived_constant_type(name, scope)
      prefix = enclosing_class_path(scope)
      return nil if prefix.nil? || prefix.empty?

      first_constant_hit(peeled_nesting(prefix), name, scope) ||
        ancestor_constant_type(name, scope, prefix)
    end
    private_class_method :caller_derived_constant_type

    # One candidate name, consulted in source-precedence order: the class registry (yielding a
    # `Singleton[C]`), source-discovered classes, in-source value constants, then RBS-side
    # constants. In-source values win over RBS constant decls because the user's source is
    # authoritative for its own constants. Returns nil when no source knows `candidate`.
    def constant_type_at(candidate, scope)
      env = scope.environment

      singleton = env.singleton_for_name(candidate)
      return singleton if singleton

      in_source_class = scope.discovered_classes[candidate]
      return in_source_class if in_source_class

      in_source_value = scope.in_source_constants[candidate]
      if in_source_value
        scope.record_constant_dependency(candidate) if Analysis::DependencyRecorder.active?
        return in_source_value
      end

      env.constant_for_name(candidate)
    end
    private_class_method :constant_type_at

    # Issue #644 — the load-bearing ADR-46 edge for a constant reference: `constant:<last segment>`, keyed on
    # the NAME rather than on a file. The published value is a function of the whole project's write set for
    # the name, so it moves when a SECOND file starts or stops assigning it — a file this reader has no other
    # relationship with, and which no positive edge could reach. Matched against the publication diff
    # ({Analysis::Incremental.changed_constant_publications}). Gated by the caller on the recorder being
    # active, so an ordinary run pays one integer read.
    def record_constant_reference(name)
      segment = name.delete_prefix("::").split("::").last
      Analysis::DependencyRecorder.read_name(:constant, segment) if segment
    end
    private_class_method :record_constant_reference

    # #354 — the project classes and modules whose own constants `class_name` inherits, in Ruby's
    # ancestor order: included / prepended modules before the superclass (Ruby places mixins nearer),
    # transitively, breadth-first. `class_name` itself is excluded — step 1 already covered it.
    #
    # Only PROJECT ancestors appear. `Scope#superclass_of` / `#includes_of` carry as-written names
    # from the discovery pre-pass, and an as-written name that resolves to no discovered class or
    # module is dropped — so a `class Foo < ActiveRecord::Base` contributes nothing and a constant
    # owned by an RBS-known ancestor still resolves only if the bare name reaches it at step 3. That
    # gap is deliberate for this slice: widening to the RBS ancestor graph is a separate question
    # with its own FP surface.
    #
    # Memoised per run because step 2 runs on every constant reference whose lexical candidates all
    # miss — which is the common case for a core-class reference (`String` inside `class Foo`). The
    # bucket keys on the identity of the runner-seeded run-generation token (ADR-84 WD2), falling
    # back to the per-file discovery table for runner-less scopes, so a re-run in one process (LSP,
    # ADR-62 warm loop) cannot hit stale entries.
    def ancestor_constant_scopes(class_name, scope)
      # ADR-46: `superclass_of` / `includes_of` record a cross-file class dependency per consumer
      # file, and the memo is run-scoped rather than file-scoped — a hit would skip the recording and
      # under-record the edge for every later file. Recording runs are rare (incremental only), so
      # they simply bypass the memo rather than complicate its key.
      return compute_ancestor_constant_scopes(class_name, scope) if Analysis::DependencyRecorder.active?

      generation = scope.run_generation || scope.discovered_superclasses
      slot = Thread.current[ANCESTOR_SCOPES_KEY]
      unless slot && slot[0].equal?(generation)
        slot = [generation, {}]
        Thread.current[ANCESTOR_SCOPES_KEY] = slot
      end
      bucket = slot[1]
      bucket.fetch(class_name) { bucket[class_name] = compute_ancestor_constant_scopes(class_name, scope) }
    end
    private_class_method :ancestor_constant_scopes

    def compute_ancestor_constant_scopes(class_name, scope)
      queue = [class_name]
      seen = { class_name => true }
      out = []
      until queue.empty?
        current = queue.shift
        # Mixins first, then the superclass — Ruby's ancestor order.
        scope.includes_of(current).each do |raw|
          resolved = resolve_ancestor_name(current, raw, scope)
          next if resolved.nil? || seen[resolved]

          seen[resolved] = true
          out << resolved
          queue << resolved
        end
        raw_super = scope.superclass_of(current)
        next if raw_super.nil?

        resolved_super = resolve_ancestor_name(current, raw_super, scope)
        next if resolved_super.nil? || seen[resolved_super]

        seen[resolved_super] = true
        out << resolved_super
        queue << resolved_super
      end
      out.freeze
    end
    private_class_method :compute_ancestor_constant_scopes

    # Resolves an ancestor name AS WRITTEN (`"Base"`, or a qualified `"A::B"`) against the nesting in
    # force where the subclass's header is written — `Scope#ancestor_name_candidates`, the single
    # owner of that order, which `Scope#enqueue_ancestors` reads for method lookup and the
    # override-visibility rule reads for its own walk. Returns nil when no candidate names a
    # discovered project class or module.
    def resolve_ancestor_name(subclass_qualified, raw, scope)
      scope.ancestor_name_candidates(subclass_qualified, raw)
           .find { |candidate| known_project_namespace?(candidate, scope) }
    end
    private_class_method :resolve_ancestor_name

    def known_project_namespace?(name, scope)
      scope.discovered_superclasses.key?(name) ||
        scope.discovered_includes.key?(name) ||
        scope.discovered_classes.key?(name)
    end
    private_class_method :known_project_namespace?

    # Pulls the enclosing qualified class name out of `scope.self_type` when one is set.
    # `Nominal[T]` and `Singleton[T]` both expose `class_name`. Returns nil at the top level.
    def enclosing_class_path(scope)
      st = scope.self_type
      case st
      when Type::Nominal, Type::Singleton then st.class_name
      end
    end
    private_class_method :enclosing_class_path

    # Ruby's `Module.nesting` for the body `scope` sits in, innermost first — the chain step 1 of
    # {.resolve_constant_type} walks, and the chain `Inference::Narrowing` walks to resolve a class-guard
    # name. The single owner of the question, so a constant read and the `is_a?` / `case`-`when` / `===`
    # guard over the same spelling cannot disagree about which constant it names.
    #
    # The chain the analyzer RECORDED at declaration time wins ({Scope#with_lexical_nesting}). It is not
    # recoverable from `self_type`: `class Admin::UsersController` and `module Admin; class
    # UsersController` produce the identical `class_name`, while Ruby's nesting is
    # `[Admin::UsersController]` for the first and `[Admin::UsersController, Admin]` for the second — so a
    # bare `User` in the compact form names `::User`, and peeling the name reached `Admin::User` and
    # reported `undefined method` on correct code ([#652](https://github.com/rigortype/rigor/issues/652)).
    #
    # The peel survives only as the FALLBACK, for a scope no declaration walk built (a callee body
    # re-entered through `Scope#evaluate`, a plugin-constructed scope). A `class << expr` body is NOT
    # one of them — not even `class << SomeOtherConstant`, whose class-frame stack the evaluator
    # resets: the body inherits the enclosing chain, because Ruby pushes no `Module.nesting` entry
    # there either. Answering an empty chain there would retract resolutions the
    # engine makes today and turn correct code into `Dynamic`; a stale-but-gradual rung costs precision
    # only, which is the direction AGENTS.md § "Implementation Guidelines" mandates.
    #
    # Issue #716 — the recorded value is three-valued, and a RECORDED `[]` is not the absence of one: it is
    # the declaration walk saying "top level", and this returns it verbatim so `Module.nesting` reads what
    # Ruby reads. {.resolve_constant_type} keeps the peel for that case as a rung BELOW the top level rather
    # than through this reader, because a chain is not where an out-of-order fallback belongs.
    def lexical_nesting_chain(scope)
      recorded = scope.lexical_nesting
      return recorded if recorded

      base = enclosing_class_path(scope)
      return [] if base.nil? || base.empty?

      peeled_nesting(base)
    end

    # The peel itself: a qualified name split into the chain the NESTED spelling would have produced
    # (`"Admin::Users::Show"` → `["Admin::Users::Show", "Admin::Users", "Admin"]`). Shared by the fallback
    # above and by issue #716's below-the-top-level rung, so the two cannot drift apart.
    def peeled_nesting(base)
      parts = base.split("::")
      parts.each_index.map { |i| parts[0..-(i + 1)].join("::") }
    end
    private_class_method :peeled_nesting

    # nil when the class or method is not in RBS. Source-side facts are {.discovered_method?};
    # unifying the two is a future slice.
    def instance_method_definition(class_name, method_name, scope: nil, environment: nil)
      loader = rbs_loader_for(scope, environment)
      return nil if loader.nil?

      loader.instance_method(class_name: class_name.to_s, method_name: method_name.to_sym)
    end

    def singleton_method_definition(class_name, method_name, scope: nil, environment: nil)
      loader = rbs_loader_for(scope, environment)
      return nil if loader.nil?

      loader.singleton_method(class_name: class_name.to_s, method_name: method_name.to_sym)
    end

    # nil when the class is not in RBS, or when the loader cannot build a definition
    # (constant aliases, malformed signatures).
    def instance_definition(class_name, scope: nil, environment: nil)
      loader = rbs_loader_for(scope, environment)
      return nil if loader.nil?

      loader.instance_definition(class_name.to_s)
    rescue ::RBS::BaseError
      nil
    end

    def singleton_definition(class_name, scope: nil, environment: nil)
      loader = rbs_loader_for(scope, environment)
      return nil if loader.nil?

      loader.singleton_definition(class_name.to_s)
    rescue ::RBS::BaseError
      nil
    end

    # `[]` when the class is non-generic or not in RBS. The dispatcher uses this when binding
    # generic method types to a concrete receiver.
    def class_type_param_names(class_name, scope: nil, environment: nil)
      loader = rbs_loader_for(scope, environment)
      return [] if loader.nil?

      loader.class_type_param_names(class_name.to_s)
    end

    # Public methods take `scope:` or `environment:`; this is the one dispatch.
    def rbs_loader_for(scope, environment)
      return environment.rbs_loader if environment
      return scope.environment.rbs_loader if scope

      Scope.empty.environment.rbs_loader
    end
    private_class_method :rbs_loader_for

    # @rbs return: bool --
    #   True when the analyzed source contains a class / module declaration for the given name. Does NOT consult the
    #   RBS loader (use {.class_known?} for the union).
    def discovered_class?(class_name, scope: Scope.empty)
      scope.discovered_classes.key?(class_name.to_s)
    end

    # @rbs return: bool --
    #   True when the ScopeIndexer recorded a `def` for the given method on the given class with the matching kind.
    #
    # ADR-46 — a MISS records a negative cross-file dependency, so a consumer whose analysis
    # turned on "the project does not define this method" is re-checked once a later edit
    # defines it. The engine's own dispatch gets that edge from
    # `Scope#record_cross_file_method`, but this facade is what a PLUGIN gate reads, and a
    # contribution tier answers before dispatch reaches the engine's recording accessors —
    # rigor-railties declines its `Rails.logger` typing exactly on this probe. Without the
    # edge a warm `--incremental` run kept serving the plugin's answer after the project
    # added `def self.logger`. The key grammar is the one `IncrementalSession#negative_key_for`
    # inverts against (`Class#method` instance-side, `Class.method` singleton-side), which is
    # also what `Incremental.appeared_symbols` emits for a newly-defined method.
    def discovered_method?(class_name, method_name, kind: :instance, scope: Scope.empty)
      return true if scope.discovered_method?(class_name, method_name, kind)

      if Analysis::DependencyRecorder.active?
        symbol = "#{class_name}#{kind == :singleton ? '.' : '#'}#{method_name}"
        Analysis::DependencyRecorder.read_missing(:method, symbol)
      end
      false
    end
  end
end
