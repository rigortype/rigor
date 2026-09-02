# Reflection Facade — `Rigor::Reflection`

Status: **Public read shape, landed v0.0.7 and unchanged since.** This
module is the unified read-side facade over Rigor's three reflection
sources; per
[`docs/design/20260505-v0.1.0-readiness.md`](../design/20260505-v0.1.0-readiness.md),
landing the facade was the highest-leverage cold-start slice for
v0.1.0 readiness. The v0.1.0 plugin API was designed against it, and
none of the three extensions § *Future evolution* anticipated for that
release has been built — see the marker there.

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
- `Rigor::Reflection.rbs_class_known?(class_name, scope: nil, environment: nil)` — RBS-only variant of `class_known?`: `true` only when RBS defines the class, independent of source-discovered `class Foo; end` declarations. Use when a rule must walk RBS method tables and so needs an RBS-defined receiver specifically.
- `Rigor::Reflection.class_ordering(lhs, rhs, scope: Scope.empty)` — `:equal` / `:subclass` / `:superclass` / `:disjoint` / `:unknown` ordering between two class names. Delegates to `Environment#class_ordering`.

### Type carriers

- `Rigor::Reflection.nominal_for_name(class_name, scope: Scope.empty)` — `Rigor::Type::Nominal` for the class name, or `nil` when no source knows the class.
- `Rigor::Reflection.singleton_for_name(class_name, scope: Scope.empty)` — `Rigor::Type::Singleton` for the class name's class object, or `nil`.

### Constants

- `Rigor::Reflection.constant_type_for(constant_name, scope: Scope.empty)` — type of the named constant. Joins in-source constants (recorded by `ScopeIndexer`) and RBS-side constants. **In-source wins on collision** because the user's source is the authoritative declaration.

### Methods

- `Rigor::Reflection.instance_method_definition(class_name, method_name, scope: nil, environment: nil)` — RBS `RBS::Definition::Method` for the instance method, or `nil` when the class or method is not in RBS.
- `Rigor::Reflection.singleton_method_definition(class_name, method_name, scope: nil, environment: nil)` — RBS-side singleton (class-side) method definition, or `nil`.
- `Rigor::Reflection.instance_definition(class_name, scope: nil, environment: nil)` — the full instance-side `RBS::Definition` (whole method table / member list), or `nil`. For callers that walk the class rather than one method.
- `Rigor::Reflection.singleton_definition(class_name, scope: nil, environment: nil)` — the full singleton-side `RBS::Definition`, or `nil`.
- `Rigor::Reflection.class_type_param_names(class_name, scope: nil, environment: nil)` — the RBS-declared type-parameter names as `Array<Symbol>` (e.g. `[:Elem]` for `Array[Elem]`), or `[]` for a non-generic or unknown class. Used when binding generic method types to a concrete receiver.

The RBS-consulting methods accept **either** `scope:` **or** `environment:` (the latter for dispatcher call sites that carry no `Scope`); when neither is given they fall back to `Scope.empty`'s environment.

### Source-side discoveries

- `Rigor::Reflection.discovered_class?(class_name, scope: Scope.empty)` — `true` when the analyzed source contains a class / module declaration. Does NOT consult the RBS loader (use `class_known?` for the union).
- `Rigor::Reflection.discovered_method?(class_name, method_name, kind: :instance, scope: Scope.empty)` — `true` when `ScopeIndexer` recorded a `def` for the given method on the given class with the matching kind. The underlying table holds one value per method name, so a name defined on BOTH sides of a class (`def helper` plus a `class << self` twin) records `Scope::DiscoveryIndex::METHOD_KIND_BOTH` and MUST answer `true` for either kind — a writer that overwrites the other side's kind instead produces a false `call.undefined-method` on code that runs. A **miss** MUST record the ADR-46 negative dependency `method:<Class>#<name>` (`method:<Class>.<name>` for `kind: :singleton`) whenever `Analysis::DependencyRecorder` is active: this facade is the read a plugin's project-definition gate consults, and a contribution tier answers before dispatch reaches the engine's own recording accessors (`Scope#user_def_for` / `#singleton_def_for`), so nothing else records the edge and a warm `--incremental` re-check would serve the plugin's answer after the project defined the method. The key grammar is the one `Analysis::IncrementalSession#negative_key_for` inverts against.

## Provenance

The provenance side of the API (which source family contributed
each fact) is explicitly **out of scope for the v0.0.7 first
pass**, and remains unbuilt — it was to be a separate concern of
the plugin API, per ADR-2 § "Plugin Diagnostic Provenance" and
the readiness analysis's recommendation to keep the facade narrow
until plugin authors require provenance for diagnostic
explanations. No plugin author has asked, so the facade is still
narrow; see the marker under § *Future evolution*.

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

> **Status — none of the three axes below shipped (as of this writing).** They were anticipated for
> the v0.1.0 plugin API; that release came and went, and `lib/rigor/reflection.rb` still carries no
> provenance surface, no Rigor-side `MethodDefinition` carrier, and no cache-slice descriptors. They
> are recorded here as intent, not as contract — a reader implementing against this document (the
> `rigor-rs` port in particular) must not expect them. Per
> [ADR-92](../adr/92-normative-status-fidelity.md) WD2 the intent is marked rather than deleted.

Three axes were called out in
[`docs/design/20260505-v0.1.0-readiness.md`](../design/20260505-v0.1.0-readiness.md):

- **Provenance** — every read returns a `(value, source_family)`
  pair so plugin diagnostics can explain why a fact came from
  source / RBS / generated / plugin.
- **Unified `MethodDefinition` carrier** — `instance_method_definition`
  returns the raw `RBS::Definition::Method`; the axis was a Rigor-side
  carrier joining source `def` nodes, RBS sigs, and plugin dynamic
  members under one shape.
- **Cache slice descriptors** — each read returns or accepts a
  cache key derived from the typed-slot schema in ADR-2 § "Cache
  Invalidation Needs a Declarative API", so plugin facts that
  depend on a reflection lookup invalidate cleanly when the
  underlying source changes.

These are not part of the v0.0.x contract.
