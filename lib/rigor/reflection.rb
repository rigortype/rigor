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

    # @param class_name [String, Symbol]
    # @param scope [Rigor::Scope]
    # @return [Boolean]
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

    # @return [Symbol] one of `:equal`, `:subclass`, `:superclass`,
    #   `:disjoint`, `:unknown`.
    def class_ordering(lhs, rhs, scope: Scope.empty)
      scope.environment.class_ordering(lhs, rhs)
    end

    # Returns the `Rigor::Type::Nominal` for the class name, or nil when no source knows the
    # class.
    def nominal_for_name(class_name, scope: Scope.empty)
      scope.environment.nominal_for_name(class_name)
    end

    # Returns the `Rigor::Type::Singleton` for the class name's class object, or nil when no
    # source knows the class.
    def singleton_for_name(class_name, scope: Scope.empty)
      scope.environment.singleton_for_name(class_name)
    end

    # Returns the type of the named constant. Joins in-source constants (recorded by
    # `ScopeIndexer`) and RBS-side constants. In-source wins on collision because the user's
    # source is the authoritative declaration.
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
      return constant_type_at(name, scope) if rooted

      prefix = enclosing_class_path(scope)

      # Step 1 — `Module.nesting`, innermost first. Each entry contributes only its OWN constants.
      walker = prefix
      while walker && !walker.empty?
        hit = constant_type_at("#{walker}::#{name}", scope)
        return hit if hit

        idx = walker.rindex("::")
        walker = idx ? walker[0, idx] : nil
      end

      # Step 2 (#354) — the ancestors of the innermost cresting scope, which Ruby consults BEFORE
      # falling back to the top level. Skipping this step did not merely lose a resolution: when the
      # same name also exists at top level, step 3 answered a lookup Ruby gives to the ancestor, so
      # `KEY` inside `class Sub < Base` typed as the top-level constant rather than `Base::KEY` — a
      # wrong type on correct code, which outranks any worst-case reading (AGENTS.md
      # § "Implementation Guidelines"). Only project ancestors are walked; an RBS-known superclass
      # contributes no name here (see {.ancestor_constant_scopes}).
      if prefix
        ancestor_constant_scopes(prefix, scope).each do |ancestor|
          hit = constant_type_at("#{ancestor}::#{name}", scope)
          return hit if hit
        end
      end

      # Step 3 — the bare name (top level).
      constant_type_at(name, scope)
    end

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
        # Issue #644 — a cross-file value constant resolved here: record the ADR-46 positive edge to the
        # file that assigned it, so an incremental recheck re-analyses this reader when that literal moves
        # or its file goes away. No-op unless dependency recording is active (the table is unseeded then).
        scope.record_constant_dependency(candidate) if Analysis::DependencyRecorder.active?
        return in_source_value
      end

      env.constant_for_name(candidate)
    end
    private_class_method :constant_type_at

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

    # Resolves an ancestor name AS WRITTEN (`"Base"`, or a qualified `"A::B"`) against the
    # subclass's lexical nesting, innermost first — the same walk
    # `ExpressionTyper#compute_ancestor_class_name` performs for method lookup. Returns nil when no
    # candidate names a discovered project class or module.
    def resolve_ancestor_name(subclass_qualified, raw, scope)
      segments = subclass_qualified.split("::")
      (segments.length - 1).downto(0) do |i|
        candidate = (segments[0, i] + [raw]).join("::")
        return candidate if known_project_namespace?(candidate, scope)
      end
      nil
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

    # Returns the RBS `RBS::Definition::Method` for the instance method, or nil when the
    # class or method is not in RBS. The source-side discovered-method facts are reachable
    # through {.discovered_method?}; a future slice will unify the two under a
    # `MethodDefinition` carrier.
    def instance_method_definition(class_name, method_name, scope: nil, environment: nil)
      loader = rbs_loader_for(scope, environment)
      return nil if loader.nil?

      loader.instance_method(class_name: class_name.to_s, method_name: method_name.to_sym)
    end

    # Returns the RBS `RBS::Definition::Method` for the singleton (class-side) method, or
    # nil.
    def singleton_method_definition(class_name, method_name, scope: nil, environment: nil)
      loader = rbs_loader_for(scope, environment)
      return nil if loader.nil?

      loader.singleton_method(class_name: class_name.to_s, method_name: method_name.to_sym)
    end

    # Returns the full RBS instance-side class definition (`RBS::Definition`), used by
    # callers that walk the method table or member list. Returns nil when the class is not
    # in RBS or when the loader cannot build a definition (e.g. constant aliases, malformed
    # signatures).
    def instance_definition(class_name, scope: nil, environment: nil)
      loader = rbs_loader_for(scope, environment)
      return nil if loader.nil?

      loader.instance_definition(class_name.to_s)
    rescue ::RBS::BaseError
      nil
    end

    # Returns the full RBS singleton-side class definition.
    def singleton_definition(class_name, scope: nil, environment: nil)
      loader = rbs_loader_for(scope, environment)
      return nil if loader.nil?

      loader.singleton_definition(class_name.to_s)
    rescue ::RBS::BaseError
      nil
    end

    # Returns the RBS-declared type parameter names for the class (e.g. `[:A]` for
    # `Array[A]`), or `[]` when the class is non-generic / not in RBS. Used by the dispatcher
    # when binding generic method types to a concrete receiver.
    def class_type_param_names(class_name, scope: nil, environment: nil)
      loader = rbs_loader_for(scope, environment)
      return [] if loader.nil?

      loader.class_type_param_names(class_name.to_s)
    end

    # Internal helper — resolves the RBS loader from either the `scope:` or the
    # `environment:` kwarg, defaulting to the empty scope's environment when neither is
    # given. Public methods document both spellings; the helper centralises the dispatch.
    def rbs_loader_for(scope, environment)
      return environment.rbs_loader if environment
      return scope.environment.rbs_loader if scope

      Scope.empty.environment.rbs_loader
    end
    private_class_method :rbs_loader_for

    # @return [Boolean] true when the analyzed source contains a class / module declaration
    #   for the given name. Does NOT consult the RBS loader (use {.class_known?} for the
    #   union).
    def discovered_class?(class_name, scope: Scope.empty)
      scope.discovered_classes.key?(class_name.to_s)
    end

    # @param kind [:instance, :singleton]
    # @return [Boolean] true when the ScopeIndexer recorded a `def` for the given method on
    #   the given class with the matching kind.
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
