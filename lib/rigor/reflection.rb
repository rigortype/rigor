# frozen_string_literal: true

require_relative "type"

module Rigor
  # Read-side facade over Rigor's three reflection sources:
  #
  # 1. **`Rigor::Environment::ClassRegistry`** — Ruby `Class` /
  #    `Module` objects (Integer, Float, Set, Pathname, …) registered
  #    at boot. Static; never changes during a `rigor check` run.
  # 2. **`Rigor::Environment::RbsLoader`** — RBS-side declarations
  #    (instance / singleton methods, class hierarchy, constants).
  #    Loaded on demand from the project's `sig/` directory + the
  #    bundled stdlib RBS.
  # 3. **`Rigor::Scope` discovered facts** — source-side discoveries
  #    produced by `Rigor::Inference::ScopeIndexer` (user-defined
  #    classes / modules, in-source constants, discovered method
  #    nodes, class ivar / cvar declarations).
  #
  # This module is the **stable read shape** that v0.1.0's plugin
  # API will be designed against. ADR-2 (`docs/adr/2-extension-api.md`)
  # calls out a unified reflection layer as a prerequisite for the
  # extension protocols, and `docs/design/20260505-v0.1.0-readiness.md`
  # nominates this module as the highest-leverage cold-start slice.
  #
  # The facade is **read-only and additive**. Existing call sites
  # that read directly from `Rigor::Scope` or
  # `Rigor::Environment::RbsLoader` continue to work unchanged;
  # they migrate to the facade at their own pace. The facade
  # performs no caching beyond what the underlying sources already
  # provide.
  #
  # ## Public surface (v0.0.7 first pass)
  #
  # - {.class_known?} — does any source recognise this class /
  #   module name?
  # - {.class_ordering} — `:equal` / `:subclass` / `:superclass` /
  #   `:disjoint` / `:unknown` ordering between two class names.
  # - {.nominal_for_name} — `Rigor::Type::Nominal` for the class
  #   name, joining registry + RBS lookups.
  # - {.singleton_for_name} — `Rigor::Type::Singleton` for the
  #   class name's class object.
  # - {.constant_type_for} — type of a constant (joins in-source
  #   constants and RBS-side constants).
  # - {.instance_method_definition} / {.singleton_method_definition}
  #   — RBS-side `RBS::Definition::Method` for the method, or
  #   `nil` when the method is not declared in RBS. Source-side
  #   discovered methods are exposed through {.discovered_method?}
  #   below until the unified `MethodDefinition` carrier ships.
  # - {.discovered_class?} / {.discovered_method?} — has the
  #   ScopeIndexer pass recorded the class / method as user-
  #   defined in the analyzed sources?
  #
  # The provenance side of the API (which source family contributed
  # each fact) is explicitly out of scope for the v0.0.7 first
  # pass. v0.1.0's plugin API adds it as a separate concern.
  module Reflection
    module_function

    # @param class_name [String, Symbol]
    # @param scope [Rigor::Scope]
    # @return [Boolean]
    def class_known?(class_name, scope: Scope.empty)
      return true if scope.discovered_classes.key?(class_name.to_s)

      scope.environment.class_known?(class_name)
    end

    # @return [Symbol] one of `:equal`, `:subclass`, `:superclass`,
    #   `:disjoint`, `:unknown`.
    def class_ordering(lhs, rhs, scope: Scope.empty)
      scope.environment.class_ordering(lhs, rhs)
    end

    # Returns the `Rigor::Type::Nominal` for the class name, or
    # nil when no source knows the class.
    def nominal_for_name(class_name, scope: Scope.empty)
      scope.environment.nominal_for_name(class_name)
    end

    # Returns the `Rigor::Type::Singleton` for the class name's
    # class object, or nil when no source knows the class.
    def singleton_for_name(class_name, scope: Scope.empty)
      scope.environment.singleton_for_name(class_name)
    end

    # Returns the type of the named constant. Joins in-source
    # constants (recorded by `ScopeIndexer`) and RBS-side
    # constants. In-source wins on collision because the user's
    # source is the authoritative declaration.
    def constant_type_for(constant_name, scope: Scope.empty)
      key = constant_name.to_s
      in_source = scope.in_source_constants[key]
      return in_source if in_source

      scope.environment.constant_for_name(constant_name)
    end

    # Returns the RBS `RBS::Definition::Method` for the instance
    # method, or nil when the class or method is not in RBS. The
    # source-side discovered-method facts are reachable through
    # {.discovered_method?}; a future slice will unify the two
    # under a `MethodDefinition` carrier.
    def instance_method_definition(class_name, method_name, scope: Scope.empty)
      loader = scope.environment.rbs_loader
      return nil if loader.nil?

      loader.instance_method(class_name: class_name.to_s, method_name: method_name.to_sym)
    end

    # Returns the RBS `RBS::Definition::Method` for the singleton
    # (class-side) method, or nil.
    def singleton_method_definition(class_name, method_name, scope: Scope.empty)
      loader = scope.environment.rbs_loader
      return nil if loader.nil?

      loader.singleton_method(class_name: class_name.to_s, method_name: method_name.to_sym)
    end

    # @return [Boolean] true when the analyzed source contains a
    #   class / module declaration for the given name. Does NOT
    #   consult the RBS loader (use {.class_known?} for the union).
    def discovered_class?(class_name, scope: Scope.empty)
      scope.discovered_classes.key?(class_name.to_s)
    end

    # @param kind [:instance, :singleton]
    # @return [Boolean] true when the ScopeIndexer recorded a
    #   `def` for the given method on the given class with the
    #   matching kind.
    def discovered_method?(class_name, method_name, kind: :instance, scope: Scope.empty)
      scope.discovered_method?(class_name, method_name, kind)
    end
  end
end
