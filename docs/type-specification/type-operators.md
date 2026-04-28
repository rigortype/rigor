# Type Operators

Rigor's type-operator surface combines RBS-compatible operators (`|`, `&`, `T?`, `[…]`) with internal forms used for negative facts, difference types, and shape projection.

This document defines the semantics of those operators, the diagnostic display contract, and the omission rules that keep negative-fact diagnostics readable. Reserved built-in names for refinements and type functions are catalogued in [imported-built-in-types.md](imported-built-in-types.md). The lattice in which these operators live is in [value-lattice.md](value-lattice.md).

## Operator catalog

| Form | Meaning |
| --- | --- |
| `T \| U` | Union, RBS-compatible |
| `T & U` | Intersection, RBS-compatible |
| `T?` | `T | nil`, RBS-compatible |
| `~T` | Complement of `T` within the current known domain (internal) |
| `T - U` | Difference: values in `T` excluding values in `U` (internal) |
| `key_of[T]` | Known keys of a record, hash shape, tuple, or shape-like type |
| `value_of[T]` | Union of known values of a record, hash shape, tuple, or shape-like type |
| `T[K]` | Indexed access into tuple, record, object shape, or generic container metadata |
| `if T <: U then X else Y` | Conditional type, when needed for advanced library modeling |

The final surface syntax for the Rigor-only operators (`~T`, `T - U`, conditional types) is intentionally provisional. The semantics are normative; the spellings MAY change before they are accepted in user-authored `RBS::Extended` payloads.

## Complement (`~T`)

`~T` is the complement of `T` within the **current known domain**, not "all possible Ruby objects except `T`" unless the value already has `top` as its positive domain.

In flow analysis, `~T` typically means "the previous type after excluding `T`". For example, `~"foo"` inside a value already proven to be `String | Symbol` means `(String | Symbol) - "foo"`.

Negative facts MUST NOT infer the positive domain from the excluded type. `v != "foo"` MAY refine `String` to `String - "foo"` or `"foo" | "bar"` to `"bar"`, but it MUST leave raw `untyped` as `Dynamic[top]` with a relational negative fact.

`~T` is reserved primarily for compact diagnostic display and branch-local notation. Authors SHOULD prefer `T - U` for explicit difference types in `RBS::Extended` annotations.

## Difference (`T - U`)

`T - U` is the preferred explicit authoring form for difference types. It is often easier to read than a bare complement, especially for scalar refinements such as `String - ""`.

Internally, Rigor MAY normalize difference to intersection with a negative type:

```text
T - U = T & ~U
```

This gives the notations a division of responsibility:

- `~T` is concise and useful for branch-local display, for example `~"foo"`.
- `T - U` is explicit and useful for user-authored extended signatures, for example `String - ""`.
- `T & ~U` is a convenient normalized form for implementation and reasoning.

### Domain-relative semantics

A negative fact removes values from the value's already-known positive domain. It MUST NOT introduce a new positive domain from the right-hand side of a comparison. For example:

```text
v: String
v != "foo" => v: String - "foo"

v: "foo" | "bar"
v != "foo" => v: "bar"

v: String | Symbol
v != "foo" => v: (String - "foo") | Symbol

v: untyped
v != "foo" => v: Dynamic[top] with a dynamic-origin relational fact `v != "foo"`
```

The final case is intentionally not `Dynamic[String - "foo"]`. A comparison with a string literal does not prove that an unchecked Ruby value is a `String`, and Ruby equality is method dispatch (see [control-flow-analysis.md](control-flow-analysis.md)). Rigor MAY keep the negative relation for later diagnostics or contradictions, but it MUST NOT turn a dynamic or unknown value into a narrower positive type unless an independent guard proves that domain.

### Finite vs open domains

When the current domain is finite, negative facts SHOULD normalize precisely. When the current domain is large or unknown, negative facts SHOULD be retained with a budget rather than expanded into unbounded difference chains. If the budget is exceeded, Rigor SHOULD widen the display and retain provenance that additional negative facts were omitted. The specific budget is `budgets.negative_fact_display`; see [inference-budgets.md](inference-budgets.md).

## Diagnostic display contract

Diagnostics MUST use a domain-aware display contract so users do not misread negative facts as global complements:

- If a finite domain normalizes to a small union, display the positive union. For example, `"foo" | "bar" - "foo"` displays as `"bar"`.
- If the positive domain is known and still broad, display `D - U`, such as `String - "foo"` or `Integer - 0`, rather than a bare complement.
- If multiple exclusions are retained, display a flattened difference such as `String - ("" | "foo")` instead of nested differences.
- If the current domain is `top`, prefer `top - U` or explanatory prose over bare `~U` unless the diagnostic is explicitly about a branch-local complement.
- Bare `~U` MAY be used only when the surrounding diagnostic already states the domain, for example "within `String`, value is `~"foo"`".
- If dynamic-origin provenance matters, display it separately from the domain expression when possible, for example `String - "foo"` with a dynamic-origin note, or `Dynamic[String - "foo"]` in technical traces. The `Dynamic[T]` display rule is in [diagnostic-policy.md](diagnostic-policy.md).
- If the retained-exclusion budget is exceeded, display the positive domain plus an omission note rather than an unstable long chain, such as `Integer with 12 excluded literals omitted`.

### Display examples

```text
String - "foo"      # Any String except the literal "foo"
1 | 2 | 3 - 2       # Equivalent to 1 | 3 after normalization
String - ("" | "x") # Any String except the listed literals
top - nil           # Any Ruby value except nil
~"foo"              # Only when the surrounding diagnostic states the domain
```

### Omission contract

The omission contract has a concrete shape so default diagnostics stay readable while explanations stay complete:

- The default display budget keeps the top three retained exclusions and ends the rendered list with `+N more` when more exclusions were retained internally. The display budget is `budgets.negative_fact_display` and is configurable in `.rigor.yml`. See [inference-budgets.md](inference-budgets.md).
- Selection prefers exclusions that participated most recently in narrowing decisions, then literal values over nominal bases, then lexicographic order so output is stable.
- The `+N more` suffix links to the diagnostic identifier so the user knows the full breakdown is available.
- `rigor explain <diagnostic-id>` (also `--explain` on the CLI) prints every retained exclusion, the budget that was exceeded, and the order of selection. This is Rigor's analogue to PHPStan's analysis explanation.
- Plugins MAY read the full retained-exclusion list through the `Scope` API and render their own higher-tier diagnostics from it; the default display budget is a presentation rule, not an information limit.

## Indexed access (`T[K]`) and projection (`key_of`, `value_of`)

`T[K]`, `key_of[T]`, and `value_of[T]` project information from a structured type:

- `T[K]` returns the type at index/key `K` in `T` when `T` is a tuple, record, object shape, or generic container with usable metadata.
- `key_of[T]` returns the union of known keys of `T`.
- `value_of[T]` returns the union of known values of `T`.

These forms are useful in `RBS::Extended` payloads (see [rbs-extended.md](rbs-extended.md)) and inside the analyzer for shape-aware narrowing. They erase to RBS conservatively (see [rbs-erasure.md](rbs-erasure.md)).

## Conditional types

Rigor MAY support a conditional type form `if T <: U then X else Y` for advanced library signatures. The current spelling is provisional; Rigor MUST NOT copy TypeScript syntax (`T extends U ? X : Y`) unless a concrete migration benefit appears.

Conditional types erase to a conservative union or bound when no branch can be statically chosen.
