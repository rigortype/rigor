# ADR-20: Lightweight Higher-Kinded Polymorphism (Lightweight HKT)

## Status

Proposed (2026-05-18). **No implementation commitment.** This ADR
captures the design space for a Rigor-side defunctionalised
higher-kinded type encoding (Yallop & White 2014; fp-ts) so that
slot signatures currently typed `untyped` can be tightened without
forcing real System F⊤ machinery into RBS. The concrete first
adopter is `JSON.parse`; longer-term adopters are the
`rigor-lisp-eval` demo, `rigor-dry-validation` schema results, and
the `rigor-dry-monads` `Result[T, E]` / `Maybe[T]` carriers.

The ADR exits "proposed" when (a) the type-level evaluation rules in
[`rigor-extensions.md`](../type-specification/rigor-extensions.md)
rows 22 + 23 are normatively specified, (b) at least one slice in
§ Implementation slicing is scheduled, and (c) `JSON.parse`'s RBS
slot is committed to using the new mechanism rather than `untyped`.

## Context

### The `JSON.parse` problem

The bundled stdlib RBS declares:

```rbs
# references/rbs/stdlib/json/0/json.rbs:1113
def self?.parse: (string source, ?options opts) -> untyped
```

`untyped` is the upstream rbs gem's choice. For Rigor's analyzer it
means:

- Every `JSON.parse(...)` call site widens to `Dynamic[Top]`.
- Downstream narrowing (`is_a?`, `case/in`, `dig`) is the only way
  to recover information.
- `make check` cannot flag any structurally-wrong post-parse
  access — the type is the *maximum* dynamic carrier.

The minimum-precision floor that is actually sound for
`JSON.parse` is the **recursive sum**:

```rbs
type json::value =
    nil
  | bool
  | Integer
  | Float
  | String
  | Array[json::value]
  | Hash[String, json::value]

def self?.parse: (string source) -> json::value
```

RBS already accepts recursive type aliases, so this single
replacement is a precision uplift available **today** without any
new mechanism. The reason we still want HKT is the *second*-level
precision:

1. **Key-type discrimination by option.** `JSON.parse(s,
   symbolize_names: true)` returns Hashes keyed by `Symbol`;
   without the option, by `String`. A naive RBS overload encodes
   this but does not compose well as more options are added.
2. **Schema-driven parsing.** Library authors writing
   `MySchema.from_json(str): MySchema` want the schema's static
   type to drive the parse return type.
3. **`rigor-lisp-eval` demo.** The
   [demo signature](../../examples/rigor-lisp-eval/demo/sig/lisp.rbs)
   sketches `def self.eval: [E] (E expr) -> lisp_type[E]` with a
   conditional type body that pattern-matches the literal AST.
   The demo currently ships with `(untyped) -> untyped` because no
   evaluation surface exists.
4. **`rigor-dry-monads` carriers** (queued for the dry-rb meta
   umbrella per [ADR-12](12-dry-rb-packaging.md)) need
   `Result[T, E]` and `Maybe[T]` as named *type constructors* the
   user can abstract over — exactly what Yallop-White HKT was
   invented for.

### Why "Lightweight" HKT specifically

Full higher-kinded polymorphism — quantifying over type
constructors `F[_]` — requires either:

- Adding the kind system itself to the host language (OCaml +
  modules, Scala 2/3, Haskell). RBS does not have one.
- A non-trivial source-language extension that Rigor cannot ship
  without violating [ADR-0](0-concept.md) ("application Ruby code
  stays free of Rigor-only annotation syntax") and [ADR-1](1-types.md)
  ("Rigor is an RBS superset").

Yallop & White (2014) showed that you can simulate HKT in a
language *without* type-constructor quantification by:

1. Choosing a **defunctionalised tag** (a URI / Symbol / brand) for
   each type constructor of interest.
2. Introducing a single abstract carrier `App[F, A]` parameterised
   on the tag and the argument.
3. Maintaining a **type-level registry** that maps each tag to its
   concrete instantiation, with `inj`/`prj` (sometimes called
   `Kind`) functions for the round trip.

fp-ts implements this verbatim in TypeScript via declaration
merging:

```typescript
// fp-ts/src/HKT.ts
export interface URItoKind<A> {}                  // open registry
export type URIS = keyof URItoKind<any>           // all registered tags
export type Kind<URI extends URIS, A> =           // indexed projection
    URI extends URIS ? URItoKind<A>[URI] : any
export interface HKT<URI, A> {                    // brand carrier
  readonly _URI: URI
  readonly _A: A
}
```

A library registers a tag by merging a single line into
`URItoKind<A>`:

```typescript
declare module 'fp-ts/HKT' {
  interface URItoKind<A> {
    readonly Option: Option<A>
  }
}
```

After registration, generic code can quantify over `URI extends
URIS` and recover the underlying type via `Kind<URI, A>`. This is
**not** real HKT — there is no type-constructor-level abstraction
in TypeScript — but for the purposes of writing
`Functor<F>`-shaped libraries, it is sufficient.

### What Rigor already has that is close

The Rigor extension catalog already lists, as "MAY support for
library signatures":

> [`docs/type-specification/rigor-extensions.md`](../type-specification/rigor-extensions.md)
> rows 22 + 23 + § "How extensions interact with the rest of the type
> system"
>
> - **Conditional type** — Models type-level branching when needed
>   for library signatures. RBS erasure: conservative union or
>   bound.
> - **Indexed access type** — Projects member, tuple, record, or
>   shape component types. RBS erasure: projected RBS type when
>   expressible, otherwise conservative base.

These two rows are the underlying machinery Lightweight HKT will be
built on top of: the defunctionalised tag lookup is an indexed
access; the per-tag concrete instantiation is a conditional type
body. ADR-20 normatively pins those rows, adds the `App[F, A]`
carrier, and standardises the authoring surface.

The plugin side already has [ADR-13's `Plugin::TypeNodeResolver`](13-typenode-resolver-plugin.md) —
the chain through which plugins translate annotation-payload type
names into Rigor types. ADR-20's registry naturally sits in that
chain.

## Goals

1. **Replace `JSON.parse`'s `untyped` slot with a recursive,
   option-discriminating return type** that Rigor's narrowing can
   work with.
2. **Provide a single, declarative authoring surface** in
   RBS-extended annotations for registering type-constructor tags
   and writing type-level functions over them.
3. **Stay backward-compatible with vanilla RBS.** Lightweight HKT
   forms MUST erase to a sound RBS expression
   ([ADR-1](1-types.md)).
4. **Reuse the existing conditional / indexed-access rows** in
   `rigor-extensions.md` rather than introducing a separate
   evaluation system.
5. **Support both library authors and plugin authors.** Library
   authors register tags through annotations in shipped `.rbs`;
   plugin authors register tags through the `Plugin::TypeNodeResolver`
   chain ([ADR-13](13-typenode-resolver-plugin.md)).
6. **Make the `rigor-lisp-eval` demo's `untyped` boundary
   removable** as the first cross-cutting validation that the
   mechanism is expressive enough.

## Non-Goals

- **Real HKT.** No quantification over type constructors at the
  user surface. Lightweight HKT is a defunctionalised encoding,
  not a kind system.
- **Higher-rank polymorphism.** Per the [type-theory
  appendix](../handbook/appendix-type-theory.md) § "What Rigor does
  NOT model", System F⊤ stays out of scope.
- **SMT-driven refinement evaluation.** The type-level computation
  here is decidable structural pattern matching, not Liquid
  Types-style predicate solving.
- **A new ".rbsx" file format.** All authoring lives in
  `%a{rigor:v1:…}` annotations inside existing `.rbs` files
  (ADR-0 boundary).
- **Inference of new HKT registrations from Ruby code.** Plugins
  contribute registrations; the analyzer never invents tags.
- **Auto-monomorphisation.** When a Lightweight HKT type cannot be
  resolved at a call site, it erases to its declared bound
  (typically `Dynamic[Top]`), not to a synthetic monomorphic copy.

## Decision (proposed shape)

### D1 — The `App[F, A]` carrier

A new internal Rigor carrier `Type::App` represents an abstract
application of a defunctionalised type-constructor tag `F` to an
argument list `A`:

- `F` is a **URI** — a unique Symbol identifying the type
  constructor. URIs are namespaced as `<author>::<name>` (e.g.
  `:json::value`, `:dry_monads::result`,
  `:rigor_lisp_eval::lisp_type`) to prevent collisions across
  plugins.
- `A` is the argument list (possibly empty, possibly multi-arg
  per the fp-ts `Kind2` / `Kind3` precedent).

`App` is **opaque** until either (a) the URI's registration is
known to the analyzer and reduction succeeds, in which case `App`
unfolds to the registered concrete type; or (b) the URI is unknown
or reduction is blocked, in which case `App` erases to its declared
bound.

### D2 — Tag registration

A library or plugin registers a tag via a top-level annotation in
its shipped `.rbs`:

```rbs
%a{rigor:v1:hkt_register:
  uri: json::value
  arity: 1
  variance: [out]
  bound: untyped       # what App[json::value, K] erases to when unresolved
}

%a{rigor:v1:hkt_define:
  uri: json::value
  body: |
    nil
    | bool
    | Integer
    | Float
    | String
    | Array[App[json::value, K]]
    | Hash[K, App[json::value, K]]
  params: [K]
}
```

The same registration in compact sugar form (proposed; final
syntax TBD per Open Question OQ4):

```rbs
type json::value[K] =
    nil | bool | Integer | Float | String
  | Array[json::value[K]]
  | Hash[K, json::value[K]]
```

— with the analyzer recognising recursive `type` aliases that name
themselves on the RHS as registering the tag implicitly. This is
the *sugar* path; the explicit `%a{rigor:v1:hkt_register}` /
`%a{rigor:v1:hkt_define}` payloads remain the canonical form.

### D3 — Type-level functions via conditional types

Type-level functions are written in the conditional-type form
already listed under
[`rigor-extensions.md`](../type-specification/rigor-extensions.md)
row 22. Body grammar:

```text
<type_fn_body> ::= <conditional_chain>

<conditional_chain> ::=
    <type_expr>
  | "(" <test> "?" <type_expr> ":" <conditional_chain> ")"

<test> ::=
    <type_expr> "<:" <type_expr>
  | <type_expr> "==" <type_expr>
  | <type_expr> "in" "[" <type_expr_list> "]"
```

The `lisp-eval` demo's existing type-function sketch lives within
this grammar verbatim:

```rbs
%a{rigor:v1:hkt_define:
  uri: rigor_lisp_eval::lisp_type
  params: [E]
  body: |
      (E <: Integer ? Integer
    : (E <: Float    ? Float
    : (E <: bool     ? bool
    : (E <: [(:+ | :- | :* | :/), A, B]      ? numeric_join[lisp_type[A], lisp_type[B]]
    : (E <: [(:< | :> | :<= | :>= | :==), _, _] ? bool
    : (E <: [(:and | :or | :not), *_]           ? bool
    : (E <: [:if, _, A, B]                      ? (lisp_type[A] | lisp_type[B])
    : untyped))))))
}

def self.eval: [E] (E expr) -> App[rigor_lisp_eval::lisp_type, E]
```

### D4 — Evaluation rules

Reduction of `App[F, A]` proceeds as follows:

1. **Resolve `F`.** Look up the registered body via the analyzer's
   HKT registry; if absent, fall through to D5 (erasure).
2. **Substitute arguments.** Replace formal parameters with `A`.
3. **Evaluate conditional tests.** For each `<test>`, decide via
   the standard subtyping / structural checks. If a test is
   `maybe` (cannot decide), the surrounding `?:` arm is widened to
   the union of both branches.
4. **Recurse on nested `App`.** Reduction is structural; recursion
   depth is bounded by the **HKT-eval budget** added to
   [`inference-budgets.md`](../type-specification/inference-budgets.md).
5. **Cache.** Reduction is referentially transparent; memoise per
   `(F, normalised(A))` per analyzer pass.

### D5 — Erasure to RBS

When `App[F, A]` cannot be reduced (unknown URI, budget exhaustion,
unresolvable conditional test), it erases to:

- The `bound:` value declared at `%a{rigor:v1:hkt_register}` time,
  defaulting to `untyped`.
- For the JSON.parse case: `untyped` (status quo) until
  registration is resolved, after which the bound becomes the
  reduced `json::value` recursive type alias.

`Type#erase_to_rbs` MUST round-trip `App[F, A]` through this
bound. The round-trip never produces `App[...]` in generated RBS
output (per ADR-1).

### D6 — Authoring surface lives in RBS-extended only

Per [ADR-0](0-concept.md), Lightweight HKT annotations MUST appear
only inside `.rbs` files, never in `.rb` files. The directives are:

- `%a{rigor:v1:hkt_register: …}` — register a URI's arity,
  variance, and erasure bound.
- `%a{rigor:v1:hkt_define: …}` — bind the URI to a type-function
  body.

Both directives are top-level in a class/module scope, parsed by
the existing `RBS::Extended` annotation pipeline. The
[`rigor-extensions.md`](../type-specification/rigor-extensions.md)
catalog adds two new rows pinning these directives.

### D7 — Plugin-side registration via `Plugin::TypeNodeResolver`

Plugins that want to register HKT tags from Ruby code (rather than
from a shipped `.rbs`) extend the existing
[`Plugin::TypeNodeResolver`](13-typenode-resolver-plugin.md) chain
with a new resolver kind:

```ruby
class MyPlugin
  def manifest
    {
      type_node_resolvers: [
        { uri: :"my_plugin::container", arity: 1, ... },
      ],
      hkt_definitions: [
        { uri: :"my_plugin::container", body: ->(env, args) { ... } },
      ],
    }
  end
end
```

The body callback receives the analyzer's environment and the
already-reduced argument types; it returns a `Type` value. This is
the **escape hatch** for type-level functions whose body cannot be
spelled as a conditional/indexed-access expression — necessary for
some integrations but discouraged where the declarative form
works.

### D8 — JSON.parse specifically

The first concrete payoff. Rigor ships a *core overlay* for the
stdlib `JSON` module (analogous to how `core_ext`-style overlays
work today; see
[ADR-17](17-monkey-patch-pre-evaluation.md)):

```rbs
# sig/rigor-core/json-overlay.rbs (Rigor-bundled, not modifying upstream rbs gem)
module JSON
  %a{rigor:v1:hkt_register:
    uri: json::value
    arity: 1
    variance: [out]
    bound: untyped
  }

  %a{rigor:v1:hkt_define:
    uri: json::value
    params: [K]
    body: |
      nil | bool | Integer | Float | String
      | Array[App[json::value, K]]
      | Hash[K, App[json::value, K]]
  }

  %a{rigor:v1:return_override:
    when: { symbolize_names: true }
    type: App[json::value, Symbol]
  }
  def self?.parse: (string source, ?options opts) -> App[json::value, String]
  def self?.parse!: (string source, ?options opts) -> App[json::value, String]
end
```

The `return_override` directive (ADR-20 amendment to
[`rbs-extended.md`](../type-specification/rbs-extended.md)) lets a
single declared signature carry per-option discrimination without
exploding the overload set. When the discriminating options are
absent, the declared base return wins.

## Working decisions

- **WD1.** URIs are namespaced Symbols of the form
  `:<author>::<name>`. The analyzer rejects HKT registrations
  whose URI does not contain `::`. Reason: collision avoidance
  across plugins.
- **WD2.** The default erasure bound is `untyped`, not `Top`.
  Reason: `untyped` is what existing RBS-aware tools (Steep, ruby
  LSP) already handle gracefully; `Top` would surface
  `Dynamic[Top]` everywhere downstream and degrade the experience
  for non-Rigor consumers of the same `.rbs`.
- **WD3.** HKT-eval budget defaults to **64 reduction steps per
  call-site evaluation**. Exhaustion erases to bound and emits an
  `info`-severity diagnostic `hkt.budget-exhausted`. Reason: bounds
  termination without forcing structural recursion checks; 64 is
  generous enough for the lisp-eval demo's 7-arm conditional with
  one level of recursion.
- **WD4.** Variance annotations on `%a{rigor:v1:hkt_register}` are
  honoured at subtyping time:
  `App[F, Sub] <: App[F, Sup]` iff `F` is registered `out`-variant
  in that argument *and* `Sub <: Sup`. Default is `inv` (invariant),
  matching RBS generics.
- **WD5.** Sugar syntax via recursive `type` alias (D2 second
  block) is *aspirational*; v1 ships only the explicit `%a{…}`
  form. Sugar is a follow-up slice gated on user feedback.
- **WD6.** The `return_override` directive used by JSON.parse is
  generalised — it lives in `rbs-extended.md`, not in this ADR. It
  is the same mechanism the ADR-18 per-call-site return-type
  amendment already established for the substrate, lifted to user
  RBS.
- **WD7.** Lightweight HKT integrates with the existing
  [trinary certainty](../type-specification/relations-and-certainty.md):
  unresolvable subtyping tests inside a conditional body widen to
  the join of both branches, *certainty = `maybe`*. The robustness
  principle ([ADR-5](5-robustness-principle.md)) governs which
  side of the join "wins" at the call site.

## Implementation slicing

All slices ship behind a `dependencies.lightweight_hkt: true` opt-in
during v0.1.x stabilisation; defaults to `true` no later than the
first v0.2.x release.

### Slice 1 — Carrier + parser only

- Add `Type::App[uri, args]` carrier with no reduction logic.
- Parse `%a{rigor:v1:hkt_register}` / `%a{rigor:v1:hkt_define}`
  annotations into an in-process registry.
- Round-trip through `erase_to_rbs` returns the declared bound.
- **No call-site change.** Demonstrable via `bundle exec rigor
  type-of` on a hand-rolled `.rbs` declaring a no-op type
  function.

### Slice 2 — Conditional evaluator over registry

- Implement reduction (D4) on top of the existing conditional /
  indexed-access form already drafted in rigor-extensions.md.
- HKT-eval budget enforced.
- Cache memoisation hooked into the existing inference cache.
- **First user-visible win:** the rigor-lisp-eval demo's
  signature replaces `(untyped) -> untyped` with `App[lisp_type, E]`
  and the integration spec under
  `examples/rigor-lisp-eval/demo/spec/` upgrades from "diagnostic
  emission" to "inferred return type."

### Slice 3 — JSON.parse overlay

- Ship `sig/rigor-core/json-overlay.rbs` with the registrations in
  § Decision D8.
- Add `return_override` support to `rbs-extended.md` if not already
  shipped via ADR-18's amendment for substrate templates.
- Update the bundled JSON RBS dispatch path so `JSON.parse(str)`
  resolves to `App[json::value, String]` and reduces to the
  recursive sum at narrowing time.
- **Integration spec:** assert that a downstream method body
  calling `JSON.parse(...).fetch("key").upcase` either narrows
  successfully or surfaces a precise
  `call.method-not-found` diagnostic (no `Dynamic[Top]`
  silencing).

### Slice 4 — `rigor-dry-monads` carrier

- Adds `Result[T, E]` and `Maybe[T]` via two URI registrations.
- Validates that two-argument HKT registrations work (mirrors
  fp-ts `Kind2`).
- Unblocks the dry-monads adapter plugin queued under
  [ADR-12](12-dry-rb-packaging.md).

### Slice 5 — Sugar (recursive `type` aliases)

- Optional sugar per WD5.
- Gated on user-survey feedback that the explicit `%a{…}` form is
  too verbose for the common case.

### Slice 6 — Plugin-side resolver hookup

- Extends `Plugin::TypeNodeResolver` (ADR-13) with the
  `hkt_definitions:` manifest entry described in D7.
- Demand-driven; ships only when a plugin needs it (likeliest
  first consumer: `rigor-graphql` for schema-driven query result
  types).

## Boundary with existing ADRs

- **[ADR-0](0-concept.md)** — All Lightweight HKT authoring stays
  in `.rbs` annotations. `.rb` files remain free of Rigor-only
  syntax.
- **[ADR-1](1-types.md)** — Every `App[F, A]` carrier MUST have an
  RBS erasure via the registered `bound:`. Round-tripping is
  loss-of-precision-tolerant.
- **[ADR-2](2-extension-api.md)** — Plugin manifests gain optional
  `hkt_definitions:` entries (Slice 6); the contract is
  forward-compatible with the existing `type_node_resolvers:`
  entry.
- **[ADR-5](5-robustness-principle.md)** — When type-function
  evaluation is `maybe`, the robustness principle picks which side
  of the join wins per position (negative = lenient, positive =
  strict).
- **[ADR-6](6-cache-persistence-backend.md)** — HKT reductions are
  cache keys' inputs; per-tag registry changes invalidate the
  relevant slice.
- **[ADR-13](13-typenode-resolver-plugin.md)** — `App[F, A]` is the
  natural output type of a `Plugin::TypeNodeResolver` whose URI
  matches a registered HKT tag. The resolver chain is the wiring
  layer.
- **[ADR-14](14-rbs-sig-generation.md)** — `rigor sig-gen` never
  emits `App[F, A]` or `%a{rigor:v1:hkt_*}` annotations. HKT
  authoring stays human-written.
- **[ADR-15](15-ractor-concurrency.md)** — The HKT registry is
  per-`Environment`; under the Ractor migration it lives in the
  frozen reflection facade.
- **[ADR-17](17-monkey-patch-pre-evaluation.md)** — `pre_eval:` is
  unrelated; HKT is a signature-side mechanism, not a Ruby-source
  scan.
- **[ADR-18](18-substrate-per-call-site-return-type.md)** — The
  `return_override` mechanism this ADR uses for JSON.parse is the
  user-RBS-level generalisation of ADR-18's per-call-site
  substrate amendment.

## Alternatives considered

| Alternative | Why rejected |
| --- | --- |
| **Full HKT in RBS** | Would require either kind-system extension to RBS (out of Rigor's authority) or a Rigor-only RBS dialect that breaks ADR-1's superset stance. |
| **Inline cast at call site (`JSON.parse(s) as MySchema`)** | Pushes the work onto every user, defeats the point of inferring a recursive sum. Closest current equivalent is `rigor-sorbet`'s `T.cast`, which remains available for users who prefer it. |
| **Enumerated overloads in vanilla RBS** | Works for `JSON.parse` with one bool option, scales linearly in the number of options × discriminated values. Lisp-eval demo's 7-arm conditional with recursion is not expressible. |
| **Plugin-only `FlowContribution`** | The current rigor-lisp-eval approach. Works per plugin but does not generalise to library-authored signatures; every library would need a plugin. ADR-20's authoring surface fixes this. |
| **Implement Liquid Types / SMT-driven refinement** | Out of scope per § Non-Goals; SMT dependency, undecidable in general, doesn't compose with the existing certainty model. |
| **Adopt fp-ts's `URItoKind` shape verbatim** | TypeScript declaration merging has no RBS analogue. The `%a{rigor:v1:hkt_register}` annotation is the moral equivalent — explicit, no language extension required. |

## Open questions

- **OQ1.** Should URIs use Symbols (`:json::value`) or
  RBS-typename-like strings (`"JSON::Value"`)? Symbols are
  Ruby-idiomatic; strings are RBS-idiomatic. Tentative: Symbol.
  Revisit during Slice 1 prototype.
- **OQ2.** Should the HKT-eval budget be per-call-site (WD3
  default) or per-`Analysis::Runner` pass? Per-call-site is
  simpler; per-pass would catch global-explosion cases. Tentative:
  per-call-site with a separate global counter for diagnostics.
- **OQ3.** When two plugins register the same URI, what wins?
  Tentative: last-wins with a `dependencies.warn_hkt_uri_clash`
  flag defaulting to `:warning`. Revisit during Slice 6.
- **OQ4.** Sugar syntax: which form to ship? Three candidates:
  (a) recursive `type` alias (D2 second block); (b)
  Sorbet-`T.type_alias`-like; (c) leave only the explicit `%a{…}`
  payload. Tentative: (c) for Slice 1–3, (a) for Slice 5 if
  feedback demands it.
- **OQ5.** Should `App[F, A]` be displayed in diagnostic output as
  `App[F, A]` (faithful), `F<A>` (TS-style), or `F[A]`
  (RBS-style)? Tentative: `F[A]` — matches RBS surface.
- **OQ6.** How does HKT interact with the `Dynamic[T]` algebra?
  When `A` is `Dynamic[T]`, does the reduction produce
  `Dynamic[App[F, T]]` or `App[F, Dynamic[T]]`? Tentative: the
  former (Dynamic stays outside), matching value-lattice.md's
  algebra. Validate during Slice 2.
- **OQ7.** What is the lifetime of registered URIs across
  `Environment` reloads (LSP server, watch mode)? Tentative:
  per-`Environment`; reload re-reads the registry. Coordinate with
  ADR-15 boundary notes.
- **OQ8.** Does `rigor type-of` need a new display mode for
  reduced HKT carriers (showing the reduction chain)? Tentative:
  add `--explain-hkt` flag if user feedback wants it.

## Related ADRs

- [ADR-0](0-concept.md), [ADR-1](1-types.md),
  [ADR-2](2-extension-api.md), [ADR-5](5-robustness-principle.md),
  [ADR-13](13-typenode-resolver-plugin.md),
  [ADR-14](14-rbs-sig-generation.md), [ADR-15](15-ractor-concurrency.md),
  [ADR-18](18-substrate-per-call-site-return-type.md) — see
  § Boundary with existing ADRs.

## Background research notes

- Yallop, J. & White, L. "Lightweight Higher-Kinded
  Polymorphism." *FLOPS 2014*. The original defunctionalised-tag
  + indexed-projection encoding. Source of the `App[F, A]` shape
  this ADR proposes. <https://www.cl.cam.ac.uk/~jdy22/papers/lightweight-higher-kinded-polymorphism.pdf>
- gcanti, *fp-ts* `src/HKT.ts`. TypeScript adaptation of
  Yallop-White using declaration-merging on `URItoKind<A>`.
  Source of the URI-registry / `Kind<URI, A>` shape. The
  TypeScript `interface URItoKind<A> {}` open registry maps
  one-to-one onto Rigor's `%a{rigor:v1:hkt_register: …}`
  annotation surface.
  <https://github.com/gcanti/fp-ts/blob/master/src/HKT.ts>
- [`docs/notes/20260518-matsumoto-2008-poly-records-rigor-review.md`](../notes/20260518-matsumoto-2008-poly-records-rigor-review.md)
  — Matsumoto & Minamide 2008 explicitly note that the lack of
  polymorphic method types forces them to *manually expand* class
  definitions (`Array#0` / `Array#1`) when typing the `map`
  call-chain. Lightweight HKT in Rigor is the *signature-author*
  equivalent of that expansion done declaratively rather than
  mechanically.

## Revision history

- 2026-05-18 — initial proposal. Triggered by the user's request
  to start the design for the Lightweight HKT direction queued
  under [ROADMAP](../ROADMAP.md) § Future cycles ("Lightweight HKT
  (higher-kinded types) in DSL signatures") with the concrete
  goal of replacing `JSON.parse`'s `untyped` slot. Scope set by
  the user's chosen references: the Yallop & White 2014 paper and
  fp-ts's `HKT.ts`.
