# Reflection Facade — `Rigor::Reflection`

Status: **Public read shape (v0.0.7).** This module is the unified
read-side facade over Rigor's three reflection sources. It is the
substrate the v0.1.0 plugin API will be designed against; per
[`docs/design/20260505-v0.1.0-readiness.md`](../design/20260505-v0.1.0-readiness.md),
landing the facade was the highest-leverage cold-start slice for
v0.1.0 readiness.

The module is **read-only and additive**. Existing call sites that
read directly from `Rigor::Scope` or
`Rigor::Environment::RbsLoader` continue to work unchanged; they
migrate to the facade at their own pace.

## Reflection sources joined

| Source | What it provides | Mutability |
| --- | --- | --- |
| `Rigor::Environment::ClassRegistry` | Ruby `Class` / `Module` objects (Integer, Float, Set, Pathname, …) registered at boot. | Static during a `rigor check` run. |
| `Rigor::Environment::RbsLoader` | RBS-side declarations: instance / singleton methods, class hierarchy, constants. | Loaded on demand from the project's `sig/` directory and the bundled stdlib RBS. |
| `Rigor::Scope` discovered facts | Source-side discoveries from `Rigor::Inference::ScopeIndexer`: user-defined classes / modules, in-source constants, discovered method nodes, class ivar / cvar declarations. | Per-scope; threaded through the inference engine. |

The facade joins these sources without caching; underlying sources
already cache where it matters (`RbsLoader` memoises class
definitions; `ClassRegistry` is constant; `Scope` is an immutable
value object).

## Public API (v0.0.7 first pass)

### Existence and ordering

- `Rigor::Reflection.class_known?(class_name, scope: Scope.empty)` — `true` when ANY source recognises the class / module name.
- `Rigor::Reflection.class_ordering(lhs, rhs, scope: Scope.empty)` — `:equal` / `:subclass` / `:superclass` / `:disjoint` / `:unknown` ordering between two class names. Delegates to `Environment#class_ordering`.

### Type carriers

- `Rigor::Reflection.nominal_for_name(class_name, scope: Scope.empty)` — `Rigor::Type::Nominal` for the class name, or `nil` when no source knows the class.
- `Rigor::Reflection.singleton_for_name(class_name, scope: Scope.empty)` — `Rigor::Type::Singleton` for the class name's class object, or `nil`.

### Constants

- `Rigor::Reflection.constant_type_for(constant_name, scope: Scope.empty)` — type of the named constant. Joins in-source constants (recorded by `ScopeIndexer`) and RBS-side constants. **In-source wins on collision** because the user's source is the authoritative declaration.

### Methods

- `Rigor::Reflection.instance_method_definition(class_name, method_name, scope: Scope.empty)` — RBS `RBS::Definition::Method` for the instance method, or `nil` when the class or method is not in RBS.
- `Rigor::Reflection.singleton_method_definition(class_name, method_name, scope: Scope.empty)` — RBS-side singleton (class-side) method definition, or `nil`.

### Source-side discoveries

- `Rigor::Reflection.discovered_class?(class_name, scope: Scope.empty)` — `true` when the analyzed source contains a class / module declaration. Does NOT consult the RBS loader (use `class_known?` for the union).
- `Rigor::Reflection.discovered_method?(class_name, method_name, kind: :instance, scope: Scope.empty)` — `true` when `ScopeIndexer` recorded a `def` for the given method on the given class with the matching kind.

## Provenance

The provenance side of the API (which source family contributed
each fact) is explicitly **out of scope for the v0.0.7 first
pass**. v0.1.0's plugin API adds it as a separate concern, per
ADR-2 § "Plugin Diagnostic Provenance" and the readiness
analysis's recommendation to keep the facade narrow until plugin
authors require provenance for diagnostic explanations.

## Stability

The facade's method signatures are stable as a v0.0.x public read
shape. Adding new methods is an additive change; renaming or
removing existing methods is a breaking change requiring a major
or minor version bump.

The underlying source-of-truth dispatch may change without notice.
For example, the in-source vs RBS preference rule for
`constant_type_for` is a documented contract and stays stable;
how each source caches its lookups internally is not.

## Future evolution

The v0.1.0 plugin API extends this module along three axes,
called out in [`docs/design/20260505-v0.1.0-readiness.md`](../design/20260505-v0.1.0-readiness.md):

- **Provenance** — every read returns a `(value, source_family)`
  pair so plugin diagnostics can explain why a fact came from
  source / RBS / generated / plugin.
- **Unified `MethodDefinition` carrier** — currently
  `instance_method_definition` returns the raw
  `RBS::Definition::Method`; v0.1.0 introduces a Rigor-side
  carrier that joins source `def` nodes, RBS sigs, and plugin
  dynamic members under one shape.
- **Cache slice descriptors** — each read returns or accepts a
  cache key derived from the typed-slot schema in ADR-2 § "Cache
  Invalidation Needs a Declarative API", so plugin facts that
  depend on a reflection lookup invalidate cleanly when the
  underlying source changes.

These are not part of the v0.0.x contract.
