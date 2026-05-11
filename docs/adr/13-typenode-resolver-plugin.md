# ADR-13 — `TypeNode` resolver plugin hook + TypeScript-utility-type adapter

Status: **proposed, 2026-05-11.** Design fixed here so a
future `rigor-typescript-utility-types` plugin author can
proceed against a stable contract. Implementation queued for
v0.1.x+ (no committed milestone). ADR-12 (dry-rb packaging)
remains the next ADR slot; this ADR sits in parallel and does
not block on it.

## Context

PHPStan ships a [`TypeNodeResolverExtension`][phpstan-custom]
extension point: a class that receives a parsed PHPDoc
`TypeNode` plus the surrounding `NameScope` and returns a
custom `Type`, or `null` to fall through. The worked example
in the PHPStan docs implements TypeScript's `Pick<T, K>`
utility type — the resolver inspects the generic's head
(`Pick`), reads the two type arguments, walks the array
shape, and returns a freshly-built constant-array type with
only the picked keys. The PHPStan team uses the same hook
inside `phpstan-phpunit` to remap `Foo|MockObject` to
`Foo&MockObject`.

[phpstan-custom]: https://phpstan.org/developing-extensions/custom-phpdoc-types

Two facts about Rigor's current state shape the response:

1.  **Rigor's type-operator surface already covers several
    TypeScript utility types** as RBS-canonical operators
    ([`type-operators.md`](../type-specification/type-operators.md)):
    `T - U` covers `Exclude`, `T & U` covers `Extract`,
    `T - nil` covers `NonNullable`, `T[K]` covers indexed
    access. The list in
    [`imported-built-in-types.md`](../type-specification/imported-built-in-types.md)
    § "Deferred or rejected imports" is explicit that the
    name-level imports (`Partial`, `Required`, `Readonly`,
    `Pick`, `Omit`, `Record`, `Parameters`, `ReturnType`,
    `InstanceType`) MUST NOT land as Rigor surface forms
    "initially." The bar for inverting that MUST NOT is a
    concrete extension point that lets users opt in without
    polluting the canonical surface.

2.  **Rigor has no plugin-extensible type-node resolution.**
    The current name-resolution path for `%a{rigor:v1:return: …}`
    / `%a{rigor:v1:param: …}` / `%a{rigor:v1:assert: …}`
    payloads is hard-coded in
    `Rigor::Builtins::ImportedRefinements::Parser`. Adding a
    new head (`pick_of[…]`, `partial_of[…]`, …) currently
    requires editing the registry inside core. Plugins cannot
    contribute named-type vocabulary even when the underlying
    semantics is expressible through existing carriers.

The user's request — *"provide an API to define TypeScript-
utility-like types and ship TS-equivalent built-ins"* — has
two parts. The **API** part is the extensibility gap above.
The **built-ins** part should not pull TypeScript-canonical
names into Rigor core (the spec already rejected that); it
should ship as an opt-in plugin that maps TS names onto
Rigor-canonical operators and type functions.

## Decision

Land three additions, gated as a v0.1.x slice:

1.  **A `Plugin::TypeNodeResolver` extension point** that
    plugins implement to contribute custom named- or
    generic-type vocabulary. The resolver sits in the
    `%a{rigor:v1:…}` payload-resolution path, between the
    built-in registry (`ImportedRefinements`) and the RBS
    fallback. Returns `nil` to fall through.

2.  **A small batch of Rigor-canonical shape-projection
    type functions** (`pick_of[T, K]`, `omit_of[T, K]`,
    `partial_of[T]`, `required_of[T]`, `readonly_of[T]`)
    added to
    [`type-operators.md`](../type-specification/type-operators.md)
    and
    [`imported-built-in-types.md`](../type-specification/imported-built-in-types.md).
    These follow the existing `key_of[T]` / `value_of[T]`
    `lower_snake[…]` naming convention; their semantics are
    normative.

3.  **A `rigor-typescript-utility-types` plugin** under
    `examples/` that registers a `TypeNodeResolver`
    contributing TypeScript-canonical names (`Pick<T, K>`,
    `Omit<T, K>`, `Partial<T>`, `Required<T>`,
    `Readonly<T>`, …) and maps each to the matching Rigor
    operator or type function. Opt-in via `.rigor.yml`'s
    `plugins:` list, exactly like every other Rigor plugin.

### Why three pieces?

Each addresses a separate concern; collapsing them is wrong:

- The **resolver hook** is the durable extensibility surface.
  Other ADRs already touch named-type vocabulary
  (`rigor-units` measurement units, `rigor-rspec` matcher
  types, future `rigor-dry-types` predicate-style refinements).
  Without it, every such extension would have to upstream
  into core.
- The **canonical type functions** are where the shape
  arithmetic actually lives. Plugins are translators, not
  semantic owners. Putting `pick_of[T, K]` in core means
  there's exactly one place to specify what "pick" means
  for HashShape vs Record vs Tuple vs object shape — and
  the diagnostic display contract has one consistent
  spelling. If `Pick<T, K>` were defined by the plugin
  directly, two plugins (e.g. one shipping TypeScript names
  and one shipping Flow names) would diverge silently.
- The **example plugin** demonstrates the boundary and
  gives Sorbet-coming / TypeScript-coming users a concrete
  opt-in path without breaking the RBS-canonical default
  surface.

### `Plugin::TypeNodeResolver` shape

```ruby
module Rigor
  module Plugin
    # Extension point for resolving custom type names that
    # appear in RBS::Extended directive payloads
    # (%a{rigor:v1:return: ...}, %a{rigor:v1:param: ...},
    # %a{rigor:v1:assert: ...}). Consulted after the built-in
    # registry and before the RBS fallback.
    class TypeNodeResolver
      # @param node [Rigor::TypeNode::Base] one of
      #   Generic(head:, args:) or Identifier(name:)
      # @param scope [Rigor::TypeNode::NameScope]
      # @return [Rigor::Type::Base, nil] nil means "not mine"
      def resolve(node, scope) = nil
    end
  end
end
```

Two new public Data classes back this:

```ruby
Rigor::TypeNode::Identifier = Data.define(:name)
Rigor::TypeNode::Generic    = Data.define(:head, :args)
                              # head: String, args: [Node, …]
```

`Rigor::TypeNode::NameScope` exposes:

- `resolver` — re-entry point so the extension can recursively
  resolve its own arguments (`scope.resolver.resolve(args[0], scope)`).
  Mirrors PHPStan's `TypeNodeResolverAwareExtension` pattern
  without the circular-reference workaround (Rigor passes the
  resolver in by argument, not constructor injection).
- `class_context` — the surrounding class / module name, if any.
- `type_alias_table` — a read-only view of the project's RBS
  type aliases for forward references.

The resolver invocation order is:

1.  `Builtins::ImportedRefinements.lookup(name)` — built-in
    no-arg refinements (`non-empty-string`, etc.).
2.  `Builtins::ImportedRefinements::Parser` — built-in
    parameterised forms (`non-empty-array[T]`, `int<a, b>`,
    `pick_of[T, K]`, …; this row gains the new type
    functions from decision (2)).
3.  **Plugin resolvers, in plugin registration order.** Each
    plugin's `TypeNodeResolver#resolve(node, scope)` is called;
    the first non-nil return wins.
4.  RBS fallback (`RBS::Parser.parse_type`) for ordinary class
    instances, aliases, and generics.
5.  Resolution failure → `dynamic.rbs-extended.unresolved`
    diagnostic; the affected slot degrades to `Dynamic[top]`.

Plugin registration uses the existing manifest:

```ruby
class RigorTypescriptUtilityTypes < Rigor::Plugin::Base
  manifest(
    id: "typescript-utility-types",
    version: "0.1.0",
    type_node_resolvers: [Resolvers::Pick.new,
                          Resolvers::Omit.new,
                          Resolvers::Partial.new,
                          # ...
                          ]
  )
end
```

Conflict policy: two plugins MAY register resolvers; the
first non-nil return wins on a per-node basis. A
`plugin.<id>.type-node-shadow` `:info` diagnostic surfaces
when a later plugin's resolver would have produced a
**different** non-nil type for the same node (the engine
asks every resolver in debug mode but uses the first match
in normal mode). This is the same shape as ADR-9's fact-store
conflict surfacing.

### Canonical type-function additions

Rigor-canonical additions to
[`type-operators.md`](../type-specification/type-operators.md)
§ "Operator catalog" (table extension, not a new section):

| Form | Meaning |
| --- | --- |
| `pick_of[T, K]` | Subset of a record / shape with keys restricted to `K`. `K` is a union of literal-key types; `T` SHOULD be a record / HashShape / object shape. |
| `omit_of[T, K]` | Subset of a record / shape with keys in `K` removed. Dual of `pick_of`. |
| `partial_of[T]` | All required entries of `T` made optional. Maps Tuple positions to nullable-or-missing entries. |
| `required_of[T]` | All optional entries of `T` made required. Inverse of `partial_of`. |
| `readonly_of[T]` | All entries of `T` marked read-only in the current view. Composes with the existing read-only entry marker in `imported-built-in-types.md` § "Initial collection and shape refinements". |

Three semantic notes:

- These are **shape-aware** operators. Applied to a value
  whose type has no record / shape projection (e.g. raw
  `Hash[String, Integer]` without entry-level keys), they
  degrade conservatively: `pick_of[Hash[K, V], K_subset]` →
  `Hash[K, V]`, with a `dynamic.shape.lossy-projection`
  `:info` provenance marker.
- `partial_of` does **not** add `nil` to value types. It
  flips entries from required to optional. The distinction
  matters: TypeScript's `Partial<T>` implicitly widens to
  `T | undefined`; Rigor models "key absent" separately from
  "key present with nil value" per ADR-1 § "Hash shape
  semantics."
- `readonly_of[T]` is a **view-level** constraint, not a
  proof that the underlying object is frozen. Matches the
  read-only entry rule already in
  [`imported-built-in-types.md`](../type-specification/imported-built-in-types.md)
  § "Initial collection and shape refinements."

The new entries also extend
[`imported-built-in-types.md`](../type-specification/imported-built-in-types.md)
§ "Initial type functions and operators" with the same
table rows.

## Translation table: TypeScript → Rigor

The `rigor-typescript-utility-types` plugin maps TS names to
Rigor-canonical forms. Lossy mappings emit
`plugin.typescript-utility-types.degraded` at the contribution
site.

| TypeScript | Rigor | Mechanism |
| --- | --- | --- |
| `Exclude<T, U>` | `T - U` | Existing core operator |
| `Extract<T, U>` | `T & U` | Existing core operator |
| `NonNullable<T>` | `T - nil` | Existing core operator |
| `Partial<T>` | `partial_of[T]` | New core type function |
| `Required<T>` | `required_of[T]` | New core type function |
| `Readonly<T>` | `readonly_of[T]` | New core type function |
| `Pick<T, K>` | `pick_of[T, K]` | New core type function |
| `Omit<T, K>` | `omit_of[T, K]` | New core type function |
| `Record<K, V>` | `Hash[K, V]` | Direct RBS form |
| `Parameters<F>` | `Dynamic[top]` (degraded) | Function-type projection deferred |
| `ReturnType<F>` | `Dynamic[top]` (degraded) | Function-type projection deferred |
| `InstanceType<C>` | `Dynamic[top]` (degraded) | Future `instance_type[C]` per `imported-built-in-types.md:96` |
| `Awaited<P>` | `Dynamic[top]` (degraded) | Ruby has no Promise built-in |
| `ConstructorParameters<C>` | `Dynamic[top]` (degraded) | Same as `Parameters` |
| `Uppercase<S>` / `Lowercase<S>` | `Dynamic[top]` (degraded) | Compile-time string casing absent in Rigor |
| `Capitalize<S>` / `Uncapitalize<S>` | `Dynamic[top]` (degraded) | Same |
| `ThisParameterType<F>` / `OmitThisParameter<F>` | `Dynamic[top]` (degraded) | Sorbet-style `T.self_type` does similar work; not a TS-utility-types concern |
| `NoInfer<T>` | `T` (identity) | TypeScript inference-control hint; no Rigor analogue |

The "degraded" rows produce `Dynamic[top]` with a
`plugin.typescript-utility-types.unsupported` provenance
marker so the user can audit the boundary. Function-type
projections (`Parameters`, `ReturnType`) become reachable
once Rigor introduces `params_of[F]` / `return_of[F]` core
operators — queued as a follow-up.

## Boundary with ADR-2 (extension API)

ADR-2 § "Custom PHPDoc Types implication" (the row in the
PHPStan Extension Surface table reading *"Rigor should
prioritize... custom RBS-extended type parsing"*) anticipated
this hook in scope but did not pin the contract. This ADR
closes that gap by fixing the resolver shape, the invocation
order, and the conflict policy.

The hook composes with the existing
`Plugin::Base#flow_contribution_for` substrate: a resolver
returns a `Rigor::Type::Base`; that type then participates in
narrowing through the same FlowContribution machinery as
built-in types. No new fact-merging policy is required.

## Boundary with ADR-0 / ADR-1 (RBS canonical, no inline DSL)

ADR-0 prohibits Rigor-specific inline DSL in application Ruby
code. This ADR doesn't violate that:

- Rigor introduces no new DSL of its own. The new type
  functions (`pick_of`, etc.) live inside the existing
  `RBS::Extended` annotation surface (`%a{rigor:v1:…}`),
  which is already a Rigor-specific authoring channel.
- TypeScript-canonical names (`Pick<T, K>`, `Omit<T, K>`,
  …) are **plugin-supplied**, not core. Users who don't
  install the plugin never see them in resolution.

ADR-1 fixes RBS as the canonical export contract. The new
type functions extend the existing RBS-erasure contract per
[`rbs-erasure.md`](../type-specification/rbs-erasure.md):

- `pick_of[Record{a: A, b: B}, "a"]` erases to the
  underlying record's RBS spelling restricted to picked
  keys: `{ a: A }`.
- `partial_of[Record{a: A}]` erases to the RBS form with
  optional-key markers (Rigor record syntax supports this).
- `pick_of[Hash[K, V], K_subset]` erases to `Hash[K, V]`
  (conservative).
- Plugin-supplied names that don't reduce to a core function
  before erasure erase to `Dynamic[top]` → `untyped` per the
  existing dynamic-erasure rule.

## Public-API drift surface

This ADR adds:

- `Rigor::Plugin::TypeNodeResolver` (new base class).
- `Rigor::TypeNode::Identifier` (new frozen Data).
- `Rigor::TypeNode::Generic` (new frozen Data).
- `Rigor::TypeNode::NameScope` (new value object with
  `#resolver`, `#class_context`, `#type_alias_table`).
- `Rigor::Plugin::Manifest#type_node_resolvers` (new
  attr_reader; default `[]`).
- `Rigor::Builtins::ImportedRefinements::Parser` gains the
  five new type-function heads (`pick_of`, `omit_of`,
  `partial_of`, `required_of`, `readonly_of`). The parser is
  not itself part of the public API surface, but its parsing
  outputs are observable through `Type::*` carriers.
- New diagnostic identifiers:
  - `dynamic.rbs-extended.unresolved` (resolution failure
    fallback).
  - `dynamic.shape.lossy-projection` (`pick_of` / `omit_of`
    over a non-shape carrier).
  - `plugin.typescript-utility-types.degraded` (lossy TS
    mapping).
  - `plugin.typescript-utility-types.unsupported` (TS name
    with no Rigor analogue).

All updates land in `spec/rigor/public_api_drift_spec.rb` in
the same commit as the implementation.

## Implementation slicing

Recommended order; each slice independently shippable:

1.  **`Rigor::TypeNode` value objects + spec.** Pure Data
    classes; no parser changes yet. Drift snapshot landed.
2.  **`Plugin::TypeNodeResolver` base class + manifest hook.**
    `Plugin::Manifest#type_node_resolvers` reader; loader
    aggregates resolvers across plugins. No parser
    integration yet.
3.  **Parser integration in `ImportedRefinements::Parser`.**
    Inserts the "consult plugin resolvers" step at the
    correct point in the lookup chain. `dynamic.rbs-extended.unresolved`
    diagnostic for whole-payload failures.
4.  **Core type functions — phase A (record / shape carriers).**
    `pick_of[T, K]`, `omit_of[T, K]`, `partial_of[T]`,
    `required_of[T]`, `readonly_of[T]` for HashShape and
    Record carriers. Spec rows added to
    `type-operators.md` and `imported-built-in-types.md`.
5.  **Core type functions — phase B (Tuple + object shape).**
    Extends phase-A coverage to Tuple and object-shape
    carriers; lossy-projection diagnostic for non-shape
    inputs.
6.  **`examples/rigor-typescript-utility-types/`.** Plugin
    scaffold via `.codex/skills/rigor-plugin-author/SKILL.md`.
    Five resolvers (Pick, Omit, Partial, Required, Readonly)
    in the v1 cut; the seven "degraded" rows ship as
    `plugin.typescript-utility-types.unsupported` returns.
7.  **Documentation update.** Handbook chapter
    cross-references the plugin; `examples/README.md`
    comparison table grows a TypeScript-utility-types row.

The plugin extracts via `git subtree split` once the
contract stabilises, per the existing pattern (see
[Rails plugins roadmap][rails-roadmap]).

[rails-roadmap]: ../design/20260508-rails-plugins-roadmap.md

## Working decisions

### WD1 — Why a new Data-class AST instead of reusing `RBS::Types::*`?

RBS's parser doesn't know about Rigor's payload syntax
(`pick_of[T, K]`, `int<a, b>`). The existing parser in
`ImportedRefinements::Parser` is a hand-written StringScanner
walk, not an RBS-shaped tree. Adding plugin extensibility on
top of the existing parser is cheapest if the resolver sees
**Rigor's** mini-AST, not a mock-RBS one. Two Data classes
(`Identifier`, `Generic`) cover every grammar production the
parser emits.

### WD2 — Why core ships `pick_of` etc. instead of leaving them to the plugin?

Three reasons:

1.  **Shape semantics belong in core.** Picking from a
    HashShape vs from a Record vs from a Tuple has
    different rules; the lossy-projection cliff is real.
    Centralising that decision avoids plugin-by-plugin
    divergence.
2.  **RBS erasure contract.** ADR-1 requires every Rigor
    type to have a deterministic RBS erasure. Plugin-supplied
    types satisfy this through the resolver-returning-a-core-type
    pattern. If `Pick<T, K>` returned a plugin-internal type
    carrier, the erasure path would have to consult plugins
    too — circular.
3.  **Other plugins want shape projection.** `rigor-units`
    (measurement units) and `rigor-rspec` (matcher types) both
    benefit from `pick_of` / `omit_of` without needing
    TypeScript names. The functions stand alone.

### WD3 — Why plugin registration order for conflict resolution, not authority tiers?

ADR-2 § "Plugin Contribution Merging" defines authority tiers
for **flow contributions** (return types, facts, mutations).
Type-node resolution is a different operation — it's a
parse-time lookup, not a runtime fact merge. Two plugins
registering resolvers for the same name signals a
configuration choice (the user installed both); first-wins
matches the convention of `Plugin::Base#diagnostics_for_file`
(registration order). The `plugin.<id>.type-node-shadow`
diagnostic surfaces the conflict so the user can pick.

### WD4 — Why don't function-type projections (`Parameters<F>`, `ReturnType<F>`) land in this ADR?

They need a different core operator (`params_of[F]`,
`return_of[F]`) that projects from a function/proc type,
not a shape type. The semantics are well-defined but the
implementation touches the dispatcher, not just the parser.
Queued as a follow-up — when it lands, the
`rigor-typescript-utility-types` plugin grows two rows.

### WD5 — Why "first non-nil wins" instead of "highest-priority plugin wins"?

Priority systems require a centralised priority registry,
which couples plugins to each other. First-wins matches the
existing plugin-loader registration semantics and keeps
plugin gems independently extractable. Users who want a
specific resolver to win adjust the `plugins:` order in
`.rigor.yml` — the same lever they already use for diagnostic
ordering.

### WD6 — Why not let the resolver mutate `Scope`?

Same answer as ADR-2 § "Scope Object": extensions don't
mutate analyzer state. The resolver returns a `Type` (or
`nil`); the analyzer applies it through the normal
narrowing machinery. The mutation-free contract keeps
parallel analysis and caching tractable.

## Alternatives considered

| Candidate | Status | Reason |
| --- | --- | --- |
| Add TS-canonical names (`Pick`, `Omit`, …) directly to `ImportedRefinements::REGISTRY` | Rejected | `imported-built-in-types.md:101` explicitly says MUST NOT initially. Inverting requires the spec change anyway, and the plugin path achieves the same UX without polluting core. |
| Pass the raw payload string to plugins, let them parse | Rejected | Every plugin would duplicate the StringScanner walk and parse-error handling. The mini-AST is a small surface that absorbs the parser-side complexity. |
| Use RBS's existing `RBS::Types::*` AST | Rejected (WD1) | The payload grammar isn't RBS; forcing it through an RBS AST would require synthesising fake `RBS::Types::Application` nodes. |
| One mega-plugin shipping every TS, Flow, and JSDoc utility-type variant | Rejected | Couples three independent type-language adapters. Keep each as its own plugin gem; share core operators. |
| Build `Plugin::TypeNodeResolver` as a method on `Plugin::Base` (no separate class) | Rejected | A plugin may want to register multiple independent resolvers (one per name). Separating them as named classes keeps each resolver testable in isolation and lets the manifest list them explicitly. |
| Defer the hook until a second consumer beyond TS utility types materialises | Rejected | The user explicitly asked for the hook; deferring would solve the immediate use case (`Pick` etc.) by adding rows to core, which the spec already rejected. The hook is the lowest-friction unblock. |

## Open questions

- **Should `pick_of[T, K]` accept a Tuple as `T`?** TypeScript's
  `Pick` only operates on object types; in Rigor, picking by
  numeric index on a Tuple has a natural interpretation. Decision
  deferred to slice 5 — start with HashShape / Record / object
  shape, add Tuple if a concrete need surfaces.
- **Should the resolver receive `scope.type_of(...)` for inline
  type-of expressions?** PHPStan's resolver doesn't get one;
  Rigor's hook is invoked at parse time, before any call-site
  evaluation. Decision: no `type_of` on `NameScope` in v1; revisit
  if a resolver-side `typeof x` reference becomes a concrete
  request.
- **Should `partial_of[T]` widen value types to include `nil`?**
  TypeScript's `Partial<T>` does (because `undefined` is implicit
  in `T | undefined`). Rigor's HashShape distinguishes "absent"
  from "present-with-nil", so the default is to flip required-ness
  without touching value types. Open question for slice 4 — could
  add a sibling `partial_nullable_of[T]` if the distinction matters
  for a concrete consumer.
- **Should `readonly_of` interact with mutation-effect inference?**
  Marking entries read-only on the static view doesn't change the
  underlying object's runtime mutability. The diagnostic posture
  is "warn on writes through this view"; whether such a write
  should be `:warning` or `:error` is a `severity_profile`
  decision. Decision deferred to slice 4 — start with `:warning`.

## Revision history

- 2026-05-11 — initial proposal. Triggered by user request
  to "prepare an API to define TypeScript-utility-like types
  and ship TS-equivalent built-ins" with the PHPStan
  `TypeNodeResolverExtension` worked example
  (`Pick<Address, 'name' | 'surname'>`) as the reference.
  Resolution: three-piece landing — plugin hook +
  Rigor-canonical type functions + opt-in TS plugin.
