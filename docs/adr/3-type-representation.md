# ADR-3: Internal Type Representation

## Status

Draft.

ADR-3 records the design space for Rigor's internal type-object layout: the Ruby classes, modules, methods, and value objects that implement the type model. ADR-3 does **not** redefine semantics — those are owned by ADR-1 and the type specification — and it does **not** define the plugin contract — that is owned by ADR-2. ADR-3 captures the rationale and the open questions that surround the analyzer-side data shapes that ADR-1 and ADR-2 attach to.

The decisions that have stabilized are normative in [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md). When that document and this ADR disagree, the spec binds and this ADR is updated to match. The same precedence applies to the type specification: when [`docs/type-specification/`](../type-specification/) disagrees with this ADR on observable behavior, the type spec binds.

## Context

Rigor needs an internal type representation before any vertical-slice implementation can land. The type specification has stabilized enough to enumerate the forms the representation must cover (see [`docs/type-specification/rbs-compatible-types.md`](../type-specification/rbs-compatible-types.md), [`docs/type-specification/rigor-extensions.md`](../type-specification/rigor-extensions.md), [`docs/type-specification/special-types.md`](../type-specification/special-types.md), [`docs/type-specification/structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md)). ADR-1 fixes the relations and the dynamic-origin algebra ([`docs/adr/1-types.md`](1-types.md), [`docs/type-specification/relations-and-certainty.md`](../type-specification/relations-and-certainty.md), [`docs/type-specification/value-lattice.md`](../type-specification/value-lattice.md)). ADR-2 fixes the extension surface that consumes type values ([`docs/adr/2-extension-api.md`](2-extension-api.md), in particular the *Type System Object Model* and *Scope Object* sections).

The remaining decision is *how* the analyzer represents those forms in Ruby code: which classes exist, how methods are grouped, how relational answers are returned, and where the boundary between "decided" and "deferred to implementation" should fall.

## Reference Model: PHPStan `Type`

The closest practical reference is PHPStan's `Type` interface and its `TrinaryLogic` companion in `phpstan/phpstan-src`. Indicative upstream paths:

- [`src/Type/Type.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/Type.php) — the central interface every type implements.
- [`src/Type/Constant/ConstantStringType.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/Constant/ConstantStringType.php) — a representative literal-value implementation.
- [`src/Type/Accessory/`](https://github.com/phpstan/phpstan-src/tree/2.2.x/src/Type/Accessory) — refinement-only types that compose through `IntersectionType`.
- [`src/Type/Generic/`](https://github.com/phpstan/phpstan-src/tree/2.2.x/src/Type/Generic) — template parameters, variance, and generic carriers.
- [`src/TrinaryLogic.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/TrinaryLogic.php) — the three-valued result class shared by capability and relational queries.
- [`src/Type/IsSuperTypeOfResult.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/IsSuperTypeOfResult.php) and [`src/Type/AcceptsResult.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/AcceptsResult.php) — result objects that bundle a trinary answer with reason metadata.

The `phpstan-src` repository is **not** part of Rigor's submodules — `references/phpstan` carries the website (`website/`) only — so these citations are external pointers. The `references/phpstan/website/src/developing-extensions/type-system.md` document inside the Rigor checkout is the closest in-repo description.

The patterns Rigor adopts from this reference, regardless of which open question is resolved later, are:

- **Never use `instanceof` to switch on a type.** PHPStan's interface comment is explicit: callers ask `$type->isString()->yes()` rather than `$type instanceof StringType`. Rigor follows the same rule. Concrete classes are implementation details.
- **Empty/non-empty array as a monad-like witness list.** Methods such as PHPStan's `getConstantStrings(): list<ConstantStringType>` return an empty array when the analyzer cannot prove any constant string witnesses, and a non-empty list otherwise. Unions and intersections compose by combining witness lists. Rigor adopts this pattern for refinement projections.
- **Trinary results, separated from booleans.** Capability questions return a three-valued result (`yes`/`no`/`maybe`); only specific result classes wrap that value with reasons. Rigor adopts the same separation but in Ruby idiom.
- **Compound types are wrappers, not subclasses.** PHPStan's `IntersectionType`, `UnionType`, `GenericObjectType`, `ConstantArrayType`, and the accessory types compose by holding inner `Type` references. Rigor's wrappers (`Dynamic`, `Refined`, `Union`, `Intersection`, `Difference`, generic carriers) follow the same composition.

PHPStan also uses class inheritance internally for code reuse (for example `ConstantStringType extends StringType`). Rigor deliberately diverges here: the Rigor type representation has **no inheritance between type classes**. The next section explains why.

## Ruby-Specific Framing

Rigor targets Ruby. Three properties of Ruby drive deviations from the PHPStan model:

- **Every value is an object.** PHP's split between scalar and object values does not exist in Ruby. The integer literal `1` already carries class information through `1.class == Integer`. A "constant string" type and a "constant integer" type can in principle share a single Ruby carrier whose discrimination is `value.class`, although a per-class layout is also possible. This is the substance of open question 1.
- **`?`-suffixed methods conventionally return booleans.** Ruby readers expect `string?` to return `true` or `false`. Rigor's capability queries return a three-valued result. The naming convention must either drop the `?`, redefine it locally, or expose two parallel surfaces. This is the substance of open question 2.
- **Mixin-based composition is idiomatic.** Ruby modules can share trait-like behavior without imposing a class hierarchy. Rigor uses modules narrowly for shared structural-equality and identity contracts, not as a type taxonomy.

The rest of this ADR records the design rationale, the working decisions, the rejected/deferred alternatives, and the planning checklist. The decisions that have stabilized are normative in [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md); when this ADR and that document appear to disagree, the spec binds.

## Normative Contract

The decided parts of the internal type representation — immutable value objects, structural equality, no inheritance between type classes, capability queries returning `Rigor::Trinary`, refinement projections returning `Array<Type>`, compound forms as wrappers, relational queries returning result objects, factory-routed normalization, the method surface, the module layout, and the diagnostics-display routing — are normative in [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md). Engine and plugin code MUST follow that document. This ADR is retained for design rationale, the rejected/deferred options below, and the planning checklist; it MUST NOT be treated as binding for the contracts that have moved.

The engine-surface contract that surrounds those type objects (`Scope`, fact store, effect model, capability-role inference, normalization, RBS erasure routing, public stability rules) is normative in [`docs/internal-spec/implementation-expectations.md`](../internal-spec/implementation-expectations.md).

## Working Decisions

Three design questions were originally deferred so the chosen answer could be exercised in real code first. The first two are now resolved by the existing implementation; the third is resolved at the design level so subsequent slices have a consistent target. Each section below records the working decision, the rationale that landed it, and the rejected/deferred alternatives in their original "Options Considered" form so future readers see the trade-off space.

### Open Question 1: Constant Scalar and Object Shape

When the analyzer can prove that a value equals a specific Ruby literal (`1`, `"aaa"`, `:sym`, `true`, `false`, `nil`), how should that fact be carried in the type representation?

**Working Decision: Option C (hybrid).** A single `Rigor::Type::Constant` class carries any scalar-like literal (`Integer`, `Float`, `String`, `Symbol`, `Rational`, `Complex`, `true`, `false`, `nil`, plus integer-endpoint `Range`); dedicated carriers (`Tuple`, `HashShape`, `IntegerRange`, …) hold the compound and refinement shapes whose inner structure cannot compress to a single Ruby value. The implementation lives in [`lib/rigor/type/constant.rb`](../../lib/rigor/type/constant.rb) (`SCALAR_CLASSES` enumerates the accepted classes) alongside [`lib/rigor/type/tuple.rb`](../../lib/rigor/type/tuple.rb), [`lib/rigor/type/hash_shape.rb`](../../lib/rigor/type/hash_shape.rb), and [`lib/rigor/type/integer_range.rb`](../../lib/rigor/type/integer_range.rb).

The hybrid landed for the same reasons it scored best in the original analysis: scalar carriage stays compact and Ruby-idiomatic, every existing carrier already needs its own structure for inner-type references and shape policies, and the boundary between "scalar literal" and "compound shape" matches the conceptual separation in [`rigor-extensions.md`](../type-specification/rigor-extensions.md). The soft boundary is documented in [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md) (the public type-object surface) and in [`lib/rigor/type/constant.rb`](../../lib/rigor/type/constant.rb)'s `SCALAR_CLASSES` list.

The compound-of-constants question called out in the original analysis (whether `[1, 2, 3]` lifts to `Tuple[Constant[1], Constant[2], Constant[3]]` or to a constant-array carrier) is resolved in favour of `Tuple[Constant…]`. `Tuple` is the carrier; `Constant` participates only as element types. The same shape applies to `{a: 1}` lifting to `HashShape{a: Constant[1]}`.

**Options considered and rejected.**

- *Option A — Unified carrier (single `Constant` for everything, including compound literals).* Rejected because compound shapes (`Tuple`, `HashShape`, `Record`) carry inner `Rigor::Type` references and per-element policies (extra-key handling, optional keys, read-only flags) that do not compress to a single Ruby value. A unified `Constant` would have to embed those policies in every instance, conflating scalar carriage with shape policy.
- *Option B — Specialized per Ruby class (`String::Constant`, `Integer::Constant`, …).* Rejected because the per-class layout grows the class count linearly with supported literal kinds while none of the per-class behaviour the layout would buy is needed in Ruby — `value.class` dispatch in a unified carrier is just as direct as a class-pattern match, and refinement projections compose cleanly against the unified shape (see OQ3's working decision).

### Open Question 2: Trinary-Returning Predicate Naming

Capability methods return `Rigor::Trinary`, not Ruby booleans. Ruby's convention is that `?`-suffixed methods return booleans. The two facts collide.

**Working Decision: Option A (drop the `?` for trinary-returning methods).** Type-side capability and relational queries are noun/verb forms that return either a `Rigor::Trinary` (`type.top`, `type.bot`, `type.dynamic`) or a result object (`type.accepts(other, mode:)` returns `Type::AcceptsResult`). Boolean queries — including `Trinary` itself — keep the `?` suffix exactly because they DO return booleans (`Trinary#yes?`, `Trinary#no?`, `Trinary#maybe?`, `AcceptsResult#yes?`/`#no?`/`#maybe?`).

The implementation has been consistent with this rule from Slice 1: every `Rigor::Type` carrier exposes `top`, `bot`, `dynamic` (Trinary-returning, no `?`) plus `accepts(other, mode:)` (result-object returning), and `Trinary` exposes `yes?`/`no?`/`maybe?` for boolean projection. See [`lib/rigor/type/constant.rb`](../../lib/rigor/type/constant.rb), [`lib/rigor/type/nominal.rb`](../../lib/rigor/type/nominal.rb), [`lib/rigor/type/union.rb`](../../lib/rigor/type/union.rb), and [`lib/rigor/trinary.rb`](../../lib/rigor/trinary.rb).

The cross-cutting requirements remain in force:

- The `Rigor::Trinary` value object MUST have `yes?`, `no?`, `maybe?` methods; those *are* booleans by the ordinary Ruby convention.
- Every `Rigor::Type` method that returns a trinary MUST follow this convention (no per-class deviation).
- The capability surface and the relational surface agree: capability methods drop the `?`, and relational methods (return result objects) do likewise.

**Options considered and rejected.**

- *Option B — Keep the `?` and document the deviation.* Rejected because silently returning a non-boolean from a `?`-suffixed method conflicts with widely-held Ruby expectations and confuses contributors, RuboCop / lint rules, RBS authors, and IDE inlay hints. The deviation cost compounds across every type-class method.
- *Option C — Dual API (`type.string` for Trinary, `type.string?` for boolean sugar over `.yes?`).* Rejected because it doubles the surface, tempts callers to default to `?` and silently lose `maybe`-aware behavior — the exact failure mode [`relations-and-certainty.md`](../type-specification/relations-and-certainty.md) warns against — and the maintenance burden of keeping two parallel surfaces in sync grows with every new query method. The single `type.foo + foo.yes?` chain at the call site is the same character count as `type.foo?` and is unambiguous about the answer's shape.

### Open Question 3: Refinement Carrier Strategy

[`imported-built-in-types.md`](../type-specification/imported-built-in-types.md) reserves a catalogue of refinement names — `non-empty-string`, `lowercase-string`, `numeric-string`, `decimal-int-string`, `positive-int`, `non-empty-array[T]`, `non-empty-hash[K, V]`, … — that name a *subset* of an existing nominal type. The question is how the analyzer represents those subsets internally so that:

- the refinement composes with combinators (`Union`, `Intersection`, `Difference`) without introducing a parallel algebra,
- predicates whose answer is determined by the refinement (`ns.empty?` / `ns.size == 0` / `ns.size > 0` for `ns: non-empty-string`) reduce to the precise `Constant[bool]`, and
- new refinement names — including plugin-contributed ones — slot in without bespoke carrier code per name.

**Working Decision: Option C (two-tier hybrid: point-removal `Difference`, predicate-subset `Refined`).** The catalogue splits along the natural mathematical boundary so each refinement lands in the carrier that matches its shape:

- **Point-removal refinements** — value set is the base type minus a finite, statically describable set of values — use the existing `Difference[BaseType, RemovedSet]` carrier:
  - `non-empty-string` = `String - ""`
  - `non-zero-int` = `Integer - 0`
  - `non-empty-array[T]` = `Array[T] - []`
  - `non-empty-hash[K, V]` = `Hash[K, V] - {}`
  - `positive-int` and `non-negative-int` are already realised through `IntegerRange`, which is structurally a Difference against the complementary half-line and stays as the dedicated bounded-integer carrier.
- **Predicate-subset refinements** — value set is defined by a per-element predicate the analyzer cannot reduce to a finite complement — use a `Type::Refined` carrier that wraps a base type and a predicate identifier:
  - `lowercase-string` = `Refined[String, :lowercase]`
  - `uppercase-string` = `Refined[String, :uppercase]`
  - `numeric-string` = `Refined[String, :numeric]`
  - `decimal-int-string`, `octal-int-string`, `hex-int-string` — each a `Refined[String, :…]`
  - Plugin-contributed predicate refinements via ADR-2, which register a `(name, base, predicate)` triple at boot time.

Composite refinement names compose through `Intersection`: `non-empty-lowercase-string` = `Difference[String, ""] & Refined[String, :lowercase]`. The intersection algebra already exists; no per-refinement intersection rules are needed.

A canonical-name registry maps each kebab-case name to its carrier shape (`Difference` or `Refined`+predicate). Display routes through the registry so `Difference[String, ""]` prints as `non-empty-string`, `Refined[String, :lowercase]` prints as `lowercase-string`, and the parser accepts both kebab-case names and the equivalent operator forms in `RBS::Extended` payloads. The registry is the single integration point ADR-2 plugins extend.

The first implementation slice will land `non-empty-string` end to end:

- introduce `Type::Difference` as a peer of `Union` / `Intersection` in [`lib/rigor/type/`](../../lib/rigor/type/);
- add `Combinator.non_empty_string` (and the symmetric `Combinator.non_zero_int`, `Combinator.non_empty_array`, `Combinator.non_empty_hash`);
- add a catalog-tier rule that projects `String#size` over a `Difference[String, ""]` receiver to `positive-int` (which then folds `ns.size == 0` to `Constant[false]` through the existing integer-equal narrowing tier);
- add a `String#empty?` rule that returns `Constant[false]` for a non-empty-string receiver directly;
- add the canonical-name registry with the bidirectional `non-empty-string` ↔ `String - ""` mapping.

`Type::Refined` is added in a follow-up slice when the first predicate-subset refinement (likely `lowercase-string` or `numeric-string`) needs it. Until then the registry only knows Difference shapes; plugin contribution of `Refined` predicates is gated on the carrier landing.

**Rationale for choosing C over A and B.**

| Concern | Option A (Accessory) | Option B (Difference only) | Option C (chosen) |
| --- | --- | --- | --- |
| Per-name class count | One per refinement | Zero | Zero for point-removals, one shared `Refined` for predicates |
| Predicate-subset coverage | Yes | No | Yes |
| Reuse of existing combinators | New intersection rules per accessory | Full reuse of `Difference` | Full reuse of `Difference` + a single shared `Refined` |
| Plugin authoring surface | Subclass an accessory base | N/A (no predicate refinements) | Register a `(name, base, predicate)` triple |
| Display contract | Per-class `describe` | Canonical-name table | Canonical-name registry (bidirectional) |
| RBS erasure | Per-class | Universal (Difference erases to base) | Universal (`Difference` and `Refined` both erase to base) |

Option B is closer to the implementation (no new carrier classes at all), but it cannot express `lowercase-string` / `numeric-string` because those are predicate-defined, not point-set complements. Adopting B alone would leave the imported-built-in catalogue half-implemented.

Option A scales linearly with the catalogue and proliferates classes whose sole job is to encode "this base type, that predicate". Ruby modules, mixins, and `case` patterns can match a `Type::Refined.predicate` without per-class boilerplate, so the per-class layout buys nothing the unified `Refined` shape does not already provide.

Option C is the minimum-class-count answer that covers the entire catalogue: the point-removal half reuses `Difference` (one new carrier class total), the predicate half adds one shared `Refined` carrier, and the canonical-name registry handles printing and parsing for both halves uniformly.

**Predicate-evaluation propagation example.** For `ns: non-empty-string` (= `Difference[Nominal[String], Constant[""]]`), the chained projection is:

```ruby
ns.size                       # positive-int
ns.size == 0                  # Constant[false]
ns.size != 0                  # Constant[true]
ns.size > 0                   # Constant[true]
ns.empty?                     # Constant[false]
```

The route is: the catalog tier projects `String#size` over the *base* nominal as `non_negative_int`; the Difference subtracts `""` (whose size is `0`) from the receiver's value set; the size projection collapses to `positive-int` automatically because the base's `non_negative_int` minus the size-of-`""` (`Constant[0]`) is `positive-int`. The existing integer-equal narrowing tier handles `positive-int == 0 → Constant[false]` without any refinement-specific rule. `ns.empty?` returns `Constant[false]` via a one-line direct rule for `String#empty?` over a non-empty-string receiver.

When the slice lands, ADR-3 will record the working decision in the implementation notes and add a normative section to [`internal-type-api.md`](../internal-spec/internal-type-api.md) describing the `Difference` carrier's public surface, the canonical-name registry contract, and the `String#size` / `String#empty?` projection rules.

**Options considered and rejected.**

- *Option A — Per-refinement Accessory carriers + IntersectionType.* PHPStan-style. Each reserved name gets its own carrier class composed via `Intersection`. Rejected because the per-class growth is unbounded relative to the imported-built-in catalogue, while the per-class behaviour the layout would buy is already expressible through `Difference` (point-removal half) and a shared `Refined` carrier (predicate half). Each new refinement under Option A would require a new class file, new tests, and a new intersection-algebra entry. Reconciling PHPStan's accessory tier with Rigor's value-lattice rules in [`value-lattice.md`](../type-specification/value-lattice.md) would also require an extra reconciliation note that Option C avoids by reusing the lattice directly.
- *Option B — Difference type alone.* Rejected because it does not cover predicate-defined refinements (`lowercase-string`, `numeric-string`, `decimal-int-string`). Choosing B would force the catalogue to ship half-implemented or to add a parallel mechanism later — which is exactly the choice C makes once, up front. Difference remains essential under C; B's "Difference only" framing is the strict subset.

## Class Catalogue Draft

This catalogue is **not** normative. It is a checklist that the type specification is covered by the planned representation. Each entry cross-references the binding spec section.

- **Special**: `Top`, `Bot`, `Dynamic`, `Void`. `Untyped` resolves to `Dynamic[Top]` at construction; it is not a separate class. See [`special-types.md`](../type-specification/special-types.md) and [`value-lattice.md`](../type-specification/value-lattice.md).
- **Nominal**: `Nominal` (instance type for a class or module), `Singleton` (class-object type, RBS `singleton(C)`), `Self`, `Instance`, `ClassMarker`. See [`rbs-compatible-types.md`](../type-specification/rbs-compatible-types.md).
- **Structural**: `Interface` (named RBS interface), `ObjectShape` (anonymous structural type), `Capability` (capability role), `MethodSignature`, `ProcSignature`, `BlockSignature`. See [`structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md).
- **Containers**: `ArrayShape`, `Tuple`, `HashShape`, `Record`. See [`rbs-compatible-types.md`](../type-specification/rbs-compatible-types.md) for the RBS-derived forms and [`rigor-extensions.md`](../type-specification/rigor-extensions.md) for the refinements (required/optional keys, read-only entries, extra-key policy).
- **Constants**: `Constant` carries any scalar-like literal (resolved per OQ1 Option C). The carrier is implemented in [`lib/rigor/type/constant.rb`](../../lib/rigor/type/constant.rb) and admits the classes enumerated in `SCALAR_CLASSES`.
- **Combinators**: `Union` (implemented), `Intersection`, `Difference`, `Complement` (the latter three are landed incrementally by the OQ3 implementation slice and the `RBS::Extended` slice). See [`type-operators.md`](../type-specification/type-operators.md).
- **Refinements**: per OQ3 Option C, refinements split into two tiers. Point-removals use `Difference[BaseType, RemovedSet]`; predicate-subsets use `Refined[BaseType, predicate]`. `IntegerRange` stays as a dedicated bounded-integer carrier (it is structurally a Difference against the complementary half-line; the dedicated carrier optimises the common case). A canonical-name registry maps each kebab-case name to its carrier shape and back. Imported built-in refinement names are catalogued in [`imported-built-in-types.md`](../type-specification/imported-built-in-types.md).
- **Generic position carriers**: `Generic`, `TemplateParameter`, `Variance`. Variance is a tag, not a separate type form. See [`rbs-compatible-types.md`](../type-specification/rbs-compatible-types.md).

Every entry MUST satisfy the method surface in [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md). Wrappers (`Dynamic`, refinements, combinators, generic carriers) MUST forward queries into their inner types according to the algebraic rules in [`value-lattice.md`](../type-specification/value-lattice.md).

## Implementation Roadmap

The roadmap is informational, not normative. It scopes the next vertical slices that exercise the resolved Working Decisions.

The OQ1 + OQ2 carriers are landed: `Type::Constant` (unified scalar carrier), `Type::Tuple`, `Type::HashShape`, `Type::IntegerRange` (compound and refinement shapes), `Type::Union`, `Type::Top`, `Type::Bot`, `Type::Dynamic`, `Type::Nominal`, `Type::Singleton`, `Trinary`-returning capability methods, `Type::AcceptsResult` for relational answers, and `describe`/`erase_to_rbs` for each. The remaining work for OQ1/OQ2 is normative consolidation in [`internal-type-api.md`](../internal-spec/internal-type-api.md), not new carrier code.

The next slice resolves OQ3 by landing the point-removal half of Option C:

1. Add `Type::Difference[base, removed]` as a peer of `Union` / `Intersection` in [`lib/rigor/type/`](../../lib/rigor/type/), with the lattice algebra reductions documented in [`value-lattice.md`](../type-specification/value-lattice.md).
2. Add factory methods on `Combinator`: `non_empty_string`, `non_zero_int`, `non_empty_array(elem)`, `non_empty_hash(k, v)`. Each constructs the matching `Difference[…]`.
3. Add catalog-tier rules:
   - `String#size` / `String#length` over `Difference[String, ""]` → `positive-int`
   - `String#empty?` over `Difference[String, ""]` → `Constant[false]`
   - Symmetric rules for `Array#size` / `Array#empty?`, `Hash#size` / `Hash#empty?`, `Integer#zero?`.
4. Add the canonical-name registry: `non-empty-string` ↔ `Difference[String, ""]`, `non-zero-int` ↔ `Difference[Integer, 0]`, etc. Display routes through it; RBS::Extended parsing recognises both forms.
5. Add a self-asserting integration fixture (`spec/integration/fixtures/non_empty_string.rb`) that demonstrates the chained projection and the canonical-name display.

A follow-up slice lands the predicate-subset half (`Type::Refined[base, predicate]`) when the first predicate-defined refinement is needed. Likely candidates in priority order:

- `lowercase-string` / `uppercase-string` (predicate over the receiver's chars)
- `numeric-string` (predicate: parses as Numeric)
- `decimal-int-string` / `octal-int-string` / `hex-int-string` (parse-target-specific)

The follow-up slice introduces:

- `Type::Refined[base, predicate_id]` as a sibling of `Difference`. `predicate_id` is a Symbol drawn from a registered predicate table (built-in plus plugin-contributed via ADR-2).
- The predicate registry: maps each `predicate_id` to a `(name, base, recogniser)` triple. The recogniser MAY be invoked at constant-fold time when the receiver is a `Constant<base>`; for non-Constant receivers the predicate stays opaque to the analyzer (the Refined carrier is a marker).
- Catalog-tier rules that project specific methods over `Refined[String, :lowercase]` etc. (e.g. `String#downcase` over a lowercase-string receiver folds to `self`).
- Canonical-name registry entries pointing to the Refined shape.

After the OQ3 slices land, subsequent work expands the catalogue: container shape refinements (`Record` extra-key policies, `Tuple` slicing), structural interfaces and capability roles, generic carriers (`Generic`, `TemplateParameter`, `Variance`), and the diagnostics-display integration in [`diagnostic-policy.md`](../type-specification/diagnostic-policy.md).

## References

Rigor documents:

- [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md) — normative public contract for the type-object surface decided by this ADR.
- [`docs/internal-spec/implementation-expectations.md`](../internal-spec/implementation-expectations.md) — engine-surface contract that surrounds the type objects.
- [`docs/adr/1-types.md`](1-types.md) — type-model semantics, dynamic-origin algebra, trinary certainty.
- [`docs/adr/2-extension-api.md`](2-extension-api.md) — extension surface that consumes Type values; *Type System Object Model* and *Scope Object* sections.
- [`docs/type-specification/relations-and-certainty.md`](../type-specification/relations-and-certainty.md) — subtyping, gradual consistency, trinary certainty.
- [`docs/type-specification/value-lattice.md`](../type-specification/value-lattice.md) — lattice identities and `Dynamic[T]` algebra.
- [`docs/type-specification/special-types.md`](../type-specification/special-types.md) — `top`, `bot`, `untyped`/`Dynamic[T]`, `void`, `nil`/`NilClass`, `bool`/`boolish`.
- [`docs/type-specification/rbs-compatible-types.md`](../type-specification/rbs-compatible-types.md) — RBS forms and contextual rules.
- [`docs/type-specification/rigor-extensions.md`](../type-specification/rigor-extensions.md) — refinements Rigor adds beyond RBS.
- [`docs/type-specification/imported-built-in-types.md`](../type-specification/imported-built-in-types.md) — reserved built-in refinement names.
- [`docs/type-specification/type-operators.md`](../type-specification/type-operators.md) — operator forms and display contract.
- [`docs/type-specification/structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md) — interfaces, shapes, capability roles.
- [`docs/type-specification/normalization.md`](../type-specification/normalization.md) — deterministic normalization rules.
- [`docs/type-specification/rbs-erasure.md`](../type-specification/rbs-erasure.md) — conservative erasure to RBS.
- [`docs/type-specification/diagnostic-policy.md`](../type-specification/diagnostic-policy.md) — identifier taxonomy and display rules.

External references (PHPStan source code; not part of Rigor's submodules — `references/phpstan` carries `website/` only):

- [`phpstan/phpstan-src` `src/Type/Type.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/Type.php).
- [`phpstan/phpstan-src` `src/Type/Constant/ConstantStringType.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/Constant/ConstantStringType.php).
- [`phpstan/phpstan-src` `src/Type/Accessory/`](https://github.com/phpstan/phpstan-src/tree/2.2.x/src/Type/Accessory).
- [`phpstan/phpstan-src` `src/Type/Generic/`](https://github.com/phpstan/phpstan-src/tree/2.2.x/src/Type/Generic).
- [`phpstan/phpstan-src` `src/TrinaryLogic.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/TrinaryLogic.php).
- [`phpstan/phpstan-src` `src/Type/IsSuperTypeOfResult.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/IsSuperTypeOfResult.php).
- [`phpstan/phpstan-src` `src/Type/AcceptsResult.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/AcceptsResult.php).

Reference docs included in the Rigor checkout via the `references/phpstan` submodule:

- [`references/phpstan/website/src/developing-extensions/type-system.md`](../../references/phpstan/website/src/developing-extensions/type-system.md).
- [`references/phpstan/website/src/developing-extensions/trinary-logic.md`](../../references/phpstan/website/src/developing-extensions/trinary-logic.md).
