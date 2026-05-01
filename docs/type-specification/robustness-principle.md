# Robustness Principle (Postel's Law for Types)

## Status

Normative.

This document defines the robustness principle that every Rigor-authored type — built-in catalog entry, inferred user-method signature, or `RBS::Extended` payload — MUST observe. Design rationale and the open questions live in [`docs/adr/5-robustness-principle.md`](../adr/5-robustness-principle.md).

## The principle

> **Returns SHOULD be as strict as can be proved without compromising soundness. Parameters SHOULD be as permissive as the body's correct behaviour permits.**

This is the type-system reading of Postel's law (the "robustness principle"): *be conservative in what you produce, be liberal in what you accept*. For Rigor specifically:

1. **Strict returns** maximise the precision of facts the inference engine can propagate downstream. A `non-negative-int` return tightens every subsequent narrowing chain that depends on the value; widening it back to `Integer` discards information for every consumer.
2. **Lenient parameters** prevent over-strict signatures from forcing callers to paste defensive coercions (`x.to_s`, `x || default`, `Array(x)`) at every call site. The narrowing tier inside the method body recovers the precise type the implementation actually needs.

Both clauses are SHOULD, not MUST: the principle directs the default choice when several correctness-preserving carriers are available. Correctness ALWAYS takes precedence over either clause.

## Where the principle applies

The principle binds wherever Rigor *authors* a type. It does NOT override RBS authorship that already exists.

| Authorship surface | Principle applies | Notes |
| --- | --- | --- |
| Built-in catalog (`data/builtins/ruby_core/*.yml`) | Yes — return tier only | Catalog overrides RBS *return* projections; parameter projections stay RBS-driven unless an `RBS::Extended` annotation is present. |
| Inferred user-method signatures | Yes — both tiers | Re-typed at the call site; the inferred return is the body's precise lattice value, the inferred parameter is the union of call-site types. |
| `RBS::Extended` annotations a user authors | Yes — both tiers | A `%a{rigor:v1:return-refinement: …}` MAY tighten the return; capability-role / `_ToFoo` parameter annotations MAY widen the parameter. |
| Hand-written RBS signatures (the user's own `.rbs` files, rbs-inline annotations) | NO | RBS authorship binds. The principle MUST NOT silently rewrite a user-supplied signature. |
| Vendored / stdlib RBS bundled with the `rbs` gem | NO | Same: those signatures bind their declared shape. The catalog tier may layer a tighter return on top, but it MUST NOT override a parameter type. |

## Strict returns: clause 1

Rigor's existing carriers are the precision tools the principle directs the analyzer to reach for. In order of decreasing precision:

| Carrier | When to prefer | Example |
| --- | --- | --- |
| `Constant[v]` | Result is statically determined | `1 + 2` → `Constant[3]` |
| `Tuple[T1, …, Tn]` | Fixed-arity heterogeneous container | `5.divmod(3)` → `Tuple[Constant[1], Constant[2]]` |
| `HashShape{k: T, …}` | Symbol-keyed record with known keys | `{name: "A", age: 30}` |
| `IntegerRange[a, b]` | Bounded integer | `Array#size` → `non-negative-int` |
| `Union[T1, …, Tn]` | Finite, small set of distinct possibilities | `n.even? ? :even : :odd` → `Constant[:even] | Constant[:odd]` |
| `Nominal[Class[args]]` | A class with applied generic arguments | `Array#map { String }` → `Array[String]` |
| `Nominal[Class]` | Raw nominal | `Object#dup` → `self` (still a nominal) |
| `Dynamic[T]` | Last-resort gradual fallback | When nothing more specific can be proved |

A clause-1 candidate MUST NOT be adopted if it would falsely exclude values that the implementation actually returns. The principle is "as strict as proven", not "as strict as imaginable".

### Concrete patterns

- **Bounded integers from container queries.** `Array#size`, `String#length`, `Hash#size`, `Range#size`, `Set#size` SHOULD return `non-negative-int` rather than `Nominal[Integer]`. The bound is a structural truth (no negative size) and propagates through every subsequent comparison.
- **Iterator-block parameters.** `Integer#times`, `Integer#upto`, `Integer#downto`, `Range#each`, and similar SHOULD bind the block's index parameter to the precise `IntegerRange` of the iteration domain rather than to the container's element type alone.
- **Tuple-shaped returns.** Methods that return a fixed-arity heterogeneous array (e.g. `Integer#divmod`) SHOULD surface as `Tuple[…]` so multi-target destructuring threads the per-slot type into locals.
- **Constant folding under the catalog.** Any method classified `:leaf` / `:trivial` / `:leaf_when_numeric` whose receiver and arguments are concrete constants SHOULD fold to a `Constant`. The `MethodCatalog` layer is the toolchain that observes clause 1 across the broadest method surface.

### When clause 1 yields

- **The contract is for all callers**, not the current call site. A signature describes the method's promise to every caller; clause 1 does NOT permit tightening a method's signature for a specific call. That work belongs to `ConstantFolding` and the per-call-site dispatcher tier.
- **The body genuinely returns the wider type.** `Array#each` returns `self`, not the block's return type. `Object#tap` returns `self`. Clause 1 does NOT permit advertising a tighter return that the body never produces.
- **The user has supplied an RBS signature.** A hand-written or rbs-inline-supplied return type binds; clause 1 only operates when Rigor authors the signature.

## Lenient parameters: clause 2

Parameter authorship reaches for the widest correctness-preserving carrier. In order of decreasing leniency:

| Carrier | When to prefer | Example |
| --- | --- | --- |
| Capability role (`_ReadableStream`, `_ToS`, …) | The body uses only the methods the role lists | `def write(stream) = stream.write(...)` → `_Writable` |
| Structural interface (RBS `interface _Foo`) | The body uses a small fixed surface | `def each(enum)` → `_Each[T]` |
| `Union[T1, T2]` | The body handles each case explicitly | `def render(content) = content.nil? ? "" : content.to_s` → `String | nil` |
| `Nominal[Superclass]` | The body uses only superclass methods | `def add(numeric)` → `Numeric`, not `Integer` |
| `Nominal[ExactClass]` | The body genuinely requires this class | `def freeze_string(s)` → `String` only |

A clause-2 candidate MUST NOT be adopted if it would let a value reach the body that the body cannot correctly handle. The principle is "as permissive as the body permits", not "as permissive as imaginable".

### Concrete patterns

- **Capability roles over nominal classes.** When a method uses only `:write` on its argument, the parameter type SHOULD be `_Writable` (a structural role) rather than `IO`. This frees `StringIO`, `Tempfile`, custom mock objects, and any future class to satisfy the contract.
- **Structural interfaces via `RBS::Extended`.** When a method's argument needs to expose a small set of methods, an `interface _Foo` declaration in RBS plus a `%a{rigor:v1:conforms-to: _Foo}` annotation on the parameter is preferred over enumerating concrete classes in a union.
- **Nilable parameter when the body checks.** When the body has a `return if x.nil?` guard or equivalent narrowing, the parameter SHOULD be `T | nil` rather than `T`. The narrowing tier recovers the precise non-nil type inside the body.
- **Numeric supertypes.** A method that uses only `+`, `-`, `*`, `<=>` on its arguments SHOULD parameter-type as `Numeric` rather than `Integer`, even if the test suite happens to pass only integers.

### The workaround-multiplication anti-pattern

If a method's parameter is over-strict, callers paste workarounds at every call site:

```ruby
# Over-strict: render expects String only
render(content || "")
render(other.to_s)
render(nullable_field.to_s)
```

The workarounds become load-bearing — replacing them later is hard because they hide their intent. Clause 2 prevents this by *erring toward leniency at design time*. The cost of a slightly wider parameter type at the method boundary is far smaller than the cost of compounding workarounds across the codebase.

### When clause 2 yields

- **The body cannot handle the wider type.** A method that calls `arg.bit_length` cannot accept `Numeric` because `Float#bit_length` does not exist. The parameter MUST stay `Integer`.
- **The wider type would mask programmer errors.** Accepting `Object` because the body uses only `to_s` would let `nil.to_s` reach the body silently; if the contract is "non-nil string-ish", `_ToS` (a role that excludes nil) is the right widening, not `Object`.
- **The parameter is on a public boundary the user has documented as nominal.** When the user's RBS signature binds the parameter to a specific class, the principle does not override.

## Interaction with other rules

- **RBS round-trip ([ADR-1](../adr/1-types.md))**: RBS → Rigor remains lossless. Rigor → RBS remains conservatively erasing. The principle directs Rigor's authorship choices but does not change the boundary contract.
- **Subtyping vs. gradual consistency ([relations-and-certainty.md](relations-and-certainty.md))**: clause 2 widening is a subtyping move (a more permissive parameter is a supertype of a stricter one); it does NOT collapse `Dynamic[T]` into `top`.
- **Trinary certainty ([relations-and-certainty.md](relations-and-certainty.md))**: a clause-1 strict return type can still produce `maybe` answers when the precision is exactly at the boundary. The principle does not force `yes`/`no` answers where `maybe` is correct.
- **Narrowing ([control-flow-analysis.md](control-flow-analysis.md))**: clause 2 widening pairs deliberately with the narrowing tier. A wider parameter feeds a narrowing-recovered precise body — these two are designed together, not separately.
- **Erasure ([rbs-erasure.md](rbs-erasure.md))**: a strict return MAY erase to a wider RBS form on export. Clause 1 produces a strict carrier *internally*; erasure presents whatever the export rule requires. The user's view through `rigor type-of` shows the strict form.
- **Inference budgets ([inference-budgets.md](inference-budgets.md))**: clause 1 is bounded by the same budgets as the rest of the engine. A strict return that would require unbounded computation MUST yield to the budget; the principle does not authorise unbounded inference.

## Specification-level summary

| Position | Direction | Choose carrier with |
| --- | --- | --- |
| Return | Tighter (clause 1) | Smallest correctness-preserving value set |
| Parameter | Wider (clause 2) | Largest correctness-preserving value set |

When the choice is ambiguous, the analyzer SHOULD log the candidates so the catalog author or rule author can curate. When the choice would compromise correctness, the analyzer MUST yield to the safe (less precise / less permissive) option.
