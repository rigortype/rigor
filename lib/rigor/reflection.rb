# frozen_string_literal: true

require_relative "type"

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
    # This is the shared owner of the lexical-constant resolution: `Inference::ExpressionTyper`
    # reads it to type a constant read, and `Inference::Narrowing` reads it to recognise a
    # value-pinned `Constant[Regexp]` match-predicate operand.
    def resolve_constant_type(name, scope: Scope.empty)
      env = scope.environment
      discovered = scope.discovered_classes
      in_source = scope.in_source_constants
      lexical_constant_candidates(name, scope: scope).each do |candidate|
        singleton = env.singleton_for_name(candidate)
        return singleton if singleton

        in_source_class = discovered[candidate]
        return in_source_class if in_source_class

        # In-source value-bearing constants take precedence over RBS constant decls because
        # user code is the authoritative source for its own constants.
        in_source_value = in_source[candidate]
        return in_source_value if in_source_value

        value = env.constant_for_name(candidate)
        return value if value
      end
      nil
    end

    # The candidate qualified names to try, in Ruby's lexical order: most-qualified first (the
    # enclosing class path joined to `name`), then progressively less-qualified, then the bare
    # `name`. A top-level scope (no `self_type`) yields only `[name]`.
    def lexical_constant_candidates(name, scope: Scope.empty)
      prefix = enclosing_class_path(scope)
      candidates = []
      while prefix && !prefix.empty?
        candidates << "#{prefix}::#{name}"
        idx = prefix.rindex("::")
        prefix = idx ? prefix[0, idx] : nil
      end
      candidates << name
      candidates
    end
    private_class_method :lexical_constant_candidates

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
    def discovered_method?(class_name, method_name, kind: :instance, scope: Scope.empty)
      scope.discovered_method?(class_name, method_name, kind)
    end
  end
end
