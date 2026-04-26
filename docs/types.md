# Rigor Type Specification

## Status

Draft. This document defines the intended type model for Rigor. It is a product specification, not an implementation status report.

## Core Principle

Rigor's type language is a strict superset of RBS.

Every RBS type must have a lossless representation in Rigor. Every Rigor-inferred type must also have an RBS erasure so Rigor can export an approximation as ordinary RBS. Erasure may lose precision, but it must not invent a narrower type than Rigor proved.

Rigor uses RBS as the interoperability surface and a richer internal type model for inference, control-flow analysis, and diagnostics.

Rigor should aggressively learn from PHPStan and TypeScript. In particular, it should support precise literal types, finite unions, flow-sensitive narrowing, negative facts, refined scalar domains, object and hash shapes, and type operators that make practical static analysis expressive without requiring inline annotations in Ruby application code.

## Relations

Rigor distinguishes two relations:

- Subtyping, written `A <: B`, describes value-set inclusion.
- Gradual consistency, written `consistent(A, B)`, describes compatibility when `untyped` participates.

This distinction is required because `untyped` is not simply `top`. `top` is the greatest static value type. `untyped` is the dynamic type: it suppresses precise static checking at a boundary, while preserving the fact that precision was lost.

The specification avoids using `~` as the gradual-consistency relation because `~T` is reserved as the candidate notation for negative or complement types.

## Value Lattice

The ordinary value lattice has:

- `top` as the greatest type for all Ruby values.
- `bot` as the empty type for unreachable or impossible values.
- Nominal, structural, literal, union, intersection, tuple, record, proc, and refined types between them.

Important identities:

```text
bot <: T
T <: top
T | bot = T
T & top = T
T | top = top
T & bot = bot
```

`untyped` is deliberately outside this pure lattice. In joins, `T | untyped` becomes `untyped` because branch precision has been lost. In flow refinements, a guard may refine an `untyped` value inside the guarded region, but the value keeps a dynamic-origin marker for diagnostics and later joins.

## Control-Flow Analysis

Rigor performs flow-sensitive type analysis in the style of PHPStan and TypeScript.

The type environment is refined by guards, returns, raises, loop exits, pattern matches, equality comparisons, predicate methods, and plugin-provided facts. Each control-flow edge carries both positive facts and negative facts. Joins merge those facts conservatively.

Example:

```rbs
def puts: (untyped value) -> void
```

```ruby
def puts(value)
  if value == "foo"
    p value # Rigor type: "foo"
  else
    p value # Rigor type: ~"foo"
  end
end
```

In this example, the parameter begins as `untyped`. The true branch receives the positive fact `value == "foo"`, so the visible type becomes the literal type `"foo"`. The false branch receives the negative fact `value != "foo"`, displayed as `~"foo"`.

Because the original value came from `untyped`, the implementation should retain dynamic-origin provenance even when it displays the narrowed branch type. A more explicit internal form may be `untyped & ~"foo"` or `Dynamic<~"foo">`; the display form may be shorter when that is clearer.

Supported narrowing sources should include:

- Equality and inequality checks against literals and singleton values.
- `nil?` checks and nil comparisons.
- Truthiness checks, where `nil` and `false` narrow the false branch.
- `is_a?`, `kind_of?`, `instance_of?`, and class/module comparisons.
- `respond_to?` checks when the method name is statically known.
- Pattern matching and case analysis.
- Predicate methods registered by Rigor plugins.
- Assertions and guards described in `RBS::Extended` annotations.

Negative facts are first-class. Rigor should preserve facts such as "not nil", "not false", "not this literal", and "does not have this nominal class" when they improve later diagnostics.

## RBS-Compatible Types

Rigor supports every type form documented by RBS syntax.

| RBS form | Rigor interpretation | RBS erasure |
| --- | --- | --- |
| `C`, `C[A]` | Nominal instance type | Same |
| `_I`, `_I[A]` | Interface type | Same |
| `alias`, `alias[A]` | Alias reference, expanded on demand | Same or expanded alias |
| `singleton(C)` | Singleton class object type | Same |
| string, symbol, integer, `true`, `false` | Literal singleton type | Same |
| `A | B` | Union type | Same after erased operands |
| `A & B` | Intersection type | Same after erased operands |
| `T?` | `T | nil` | Optional syntax when valid, otherwise union |
| `{ key: T }` | Hash record with known keys | Same |
| `[A, B]` | Array tuple with fixed arity | Same |
| type variable | Scoped type variable with bounds and variance | Same |
| `self` | Open-recursive receiver type in self-context | Same when the RBS context allows it |
| `instance` | Current class instance type in classish-context | Same when the RBS context allows it |
| `class` | Current class singleton type in classish-context | Same when the RBS context allows it |
| `bool` | Alias for `true | false` | `bool` |
| `nil` | The singleton `nil` value | `nil` |
| `untyped` | Dynamic type | `untyped` |
| `top` | Greatest static value type | `top` |
| `bot` | Empty type | `bot` |
| `void` | Return-position no-use result marker | `void` where valid, otherwise `top` with a diagnostic |
| proc type | Callable object type | Same after erased operands |

Rigor preserves RBS contextual limitations for export. For example, `self`, `instance`, `class`, and `void` must only be emitted where RBS accepts them. If an internal type contains one of these markers in an invalid RBS context, the erasure pass must rewrite it to the nearest valid conservative type and report the loss of precision.

## Special Types

### `top`

`top` means any Ruby value. It is useful when a value exists but Rigor has no useful static structure for it.

Using a value of type `top` is still checked. A method call on `top` is accepted only when the method is known to be available for every possible inhabitant, or when a plugin supplies a stronger fact.

### `bot`

`bot` means no value can exist. It appears in unreachable branches, methods that always raise, exits, failed pattern matches, and contradictory refinements.

`bot` is useful for control-flow analysis because joining `bot` with a real branch leaves the real branch unchanged.

### `untyped`

`untyped` is the dynamic type. It is consistent with every type:

```text
consistent(untyped, T)
consistent(T, untyped)
```

Operations on `untyped` should not create false precision. A method call on `untyped` returns `untyped` unless Rigor has an explicit refinement or plugin-provided rule. Assigning `untyped` to a precise type is allowed at a gradual boundary, but Rigor should retain enough provenance to explain that the value passed through unchecked code.

### `void`

`void` is not an ordinary value type in Rigor. It is a result marker for expressions whose return value should not be used.

RBS treats `void`, `boolish`, and `top` equivalently for many type-system purposes, but Rigor keeps `void` distinct internally so it can diagnose value use:

```ruby
result = puts("hello")
# `puts` returns void; assigning or sending methods to the value is suspicious.
```

Rules:

- `void` is valid in method and proc return positions.
- `void` is valid as a generic argument only when preserving an RBS signature.
- `void` must not appear inside ordinary unions, optionals, records, tuples, or parameter types.
- In statement context, a `void` result is accepted.
- In value context, a `void` result produces a diagnostic and is materialized as `top` for downstream recovery.

### `nil`, `NilClass`, and Optional Types

`nil` is the singleton nil value. `T?` is normalized to `T | nil`.

`NilClass` is a nominal RBS type, but Rigor should prefer the singleton `nil` internally whenever it can prove the exact value. Export should prefer `nil` for singleton nil and preserve `NilClass` only when it came from an explicit external signature.

### `bool`, Truthiness, and `boolish`

`bool` is `true | false`.

Ruby conditionals accept any value as a truth value: only `false` and `nil` are falsey. Rigor models this as a flow-sensitive predicate over types, not by widening every condition to `bool`.

RBS `boolish` is an alias of `top`. Rigor should erase truthiness-accepting callback return types to `boolish` when matching an existing RBS signature, but internally it should retain the actual return type when possible.

## Rigor Extensions

Rigor may infer types that RBS cannot spell directly. These types must always erase to RBS.

| Rigor extension | Purpose | RBS erasure |
| --- | --- | --- |
| Refined nominal type, such as `String where non_empty` | Predicate-proven subtype of a nominal type | Nominal base, such as `String` |
| Integer range, such as `Integer[1..]` | Numeric comparisons and bounds | `Integer` |
| Finite set of literals | Precise branch and enum tracking | RBS literal union when possible, otherwise nominal base |
| Truthiness refinement | Branch-sensitive nil/false elimination | Erased underlying type |
| Object shape | Known methods or singleton-object capabilities inferred locally | Named interface if available, otherwise `top` or nominal base |
| Hash shape refinements beyond RBS records | Optional keys, required keys, key presence after guards | RBS record when exact, otherwise `Hash[K, V]` |
| Dynamic-origin marker | Tracks precision lost through `untyped` | Erased marker |
| Negation or complement type, such as `~"foo"` | Represents values in the current domain except a type | Erased domain type |
| Conditional type | Models type-level branching when needed for library signatures | Conservative union or bound |
| Indexed access type | Projects member, tuple, record, or shape component types | Projected RBS type when expressible, otherwise conservative base |
| Template literal-like string refinement | Tracks formatted string families | `String` |

Rigor extensions must not leak into generated RBS syntax.

## Type Operators

The final surface syntax for Rigor-only type operators is not settled. This section records the intended semantics so implementation and documentation can converge later.

Candidate operators:

| Candidate | Meaning |
| --- | --- |
| `~T` | Complement of `T` within the current known domain |
| `T - U` | Difference: values in `T` excluding values in `U` |
| `T & U` | Intersection, already RBS-compatible |
| `T | U` | Union, already RBS-compatible |
| `keyof T` | Known keys or method names of a shape-like type |
| `T[K]` | Indexed access into tuple, record, object shape, or generic container metadata |
| `T extends U ? X : Y` | Conditional type, if needed for advanced library modeling |

Rigor should treat `~T` as the preferred display notation for negative facts produced by control-flow analysis. It should not be interpreted as "all possible Ruby objects except T" unless the current domain is `top`. In flow analysis, it usually means "the previous type after excluding T".

Rigor should treat `T - U` as the preferred explicit authoring form for difference types in `RBS::Extended` annotations. It is often easier to read in library signatures than a bare complement, especially for scalar refinements such as `String - ""`.

Internally, Rigor may normalize difference to intersection with a negative type:

```text
T - U = T & ~U
```

This gives the notations a division of responsibility:

- `~T` is concise and useful for branch-local display, for example `~"foo"`.
- `T - U` is explicit and useful for user-authored extended signatures, for example `String - ""`.
- `T & ~U` is a convenient normalized form for implementation and reasoning.

Examples:

```text
String - "foo"      # Any String except the literal "foo"
1 | 2 | 3 - 2       # Equivalent to 1 | 3 after normalization
~nil               # Non-nil value within the current domain
~"foo"             # Not the literal "foo" within the current domain
```

When the domain is finite, difference and complement should normalize precisely. When the domain is large or unknown, they should become refinements rather than expanding to enormous unions.

## RBS::Extended Annotations

Rigor may read Rigor-specific metadata from RBS annotations in `*.rbs` files under the provisional name `RBS::Extended`.

RBS already supports `%a{...}` annotations on declarations, members, and method overloads. `RBS::Extended` should use that mechanism as the canonical attachment point because annotations are parsed into the RBS AST and remain associated with the signature node they describe.

These annotations let users and plugin authors describe types that exceed standard RBS without changing Ruby application code and without breaking ordinary RBS parsers. Standard RBS tools should be able to preserve or ignore these annotations.

Example:

```rbs
%a{rigor:return String where non_empty}
def read_name: () -> String

%a{rigor:param value: String - ""}
def normalize: (String value) -> String

%a{rigor:assert-if-true value is "foo"}
%a{rigor:assert-if-false value is ~"foo"}
def check: (untyped value) -> bool
```

Rules:

- The ordinary RBS signature remains the compatibility contract.
- `RBS::Extended` annotations refine or explain that contract for Rigor.
- Annotation keys use a `rigor:` namespace, for example `rigor:return` or `rigor:predicate-if-true`.
- The annotation key comes first; the remaining text is a Rigor-specific payload.
- Prefer `T - U` for explicit user-authored difference types.
- Use `~T` primarily for negative facts and compact diagnostic display.
- If an annotation conflicts with the RBS signature, Rigor must report a diagnostic.
- Exported plain RBS must drop or erase Rigor-only annotations unless the user asks to preserve them.
- The annotation grammar is provisional and should remain small until implementation experience proves it out.

### Type Predicates and Assertions

Rigor models TypeScript-style type guards and PHPStan-style assertions as flow effects attached to RBS method signatures.

Predicate examples:

```rbs
%a{rigor:predicate-if-true value is String}
%a{rigor:predicate-if-false value is ~String}
def string?: (untyped value) -> bool

%a{rigor:predicate-if-true self is LoggedInUser}
def logged_in?: () -> bool
```

Assertion examples:

```rbs
%a{rigor:assert value is String}
def assert_string!: (untyped value) -> void

%a{rigor:assert-if-true value is String}
def valid_string?: (untyped value) -> bool
```

Meanings:

- `rigor:predicate-if-true target is T` refines `target` to `T` on the true branch of a call used as a condition.
- `rigor:predicate-if-false target is T` refines `target` to `T` on the false branch.
- `rigor:assert target is T` refines `target` after the method returns normally.
- `rigor:assert-if-true target is T` refines `target` when the method returns a truthy value.
- `rigor:assert-if-false target is T` refines `target` when the method returns `false` or `nil`.

The initial target grammar should be intentionally small:

```text
target ::= parameter-name | self
```

`parameter-name` refers to an RBS method parameter name, not an arbitrary Ruby Symbol. RBS parameter names follow `_var-name_ ::= /[a-z]\w*/`, so predicate targets should follow that existing identifier style. The hyphenated words in directives such as `predicate-if-true` live inside the annotation payload and are parsed by Rigor, not as Ruby Symbols.

If a predicate needs to refer to an argument, the RBS method type must name that argument:

```rbs
# Good: `value` can be referenced.
%a{rigor:predicate-if-true value is String}
def string?: (untyped value) -> bool

# Not enough information for a predicate target.
def string?: (untyped) -> bool
```

Future versions may extend targets to instance variables, record keys, shape paths, and block parameters, but those should use explicit path syntax rather than overloading the annotation directive name.

## Normalization

Rigor normalizes types before comparison and reporting.

- Flatten nested unions and intersections.
- Remove duplicate union and intersection operands.
- Drop `bot` from unions.
- Drop `top` from intersections.
- Expand `T?` to `T | nil` internally.
- Normalize finite set difference and complement when the domain is known.
- Collapse `true | false` to `bool` for display when that is clearer.
- Preserve literal precision until it becomes too large or expensive; then widen to the nominal base.
- Preserve `untyped` explicitly rather than normalizing it to `top`.

Normalization must be deterministic so diagnostics, caches, and exported signatures are stable.

## RBS Erasure

RBS erasure converts an internal Rigor type to a valid RBS type.

Erasure rules:

- Exact RBS types erase to themselves.
- Refined types erase to their unrefined base.
- Unsupported literal kinds erase to their nominal class.
- Integer ranges erase to `Integer`.
- Complement and difference refinements erase to their current domain type.
- Object shapes erase to a matching named interface when one exists, otherwise a conservative nominal or `top`.
- Dynamic-origin markers are removed.
- Invalid-context `void`, `self`, `instance`, or `class` forms are rewritten to valid conservative RBS and reported as precision loss.

Erasure is conservative: if `erase(T) = R`, then every value accepted by `T` must be accepted by `R`.

## Diagnostic Policy

Rigor should prefer precise diagnostics over silent widening.

- Using `void` as a value is a diagnostic.
- Calling a method on `top` without proof is a diagnostic.
- Calling a method on `untyped` is allowed but should be traceable to an unchecked boundary.
- A branch narrowed by a negative fact should display that fact when it is useful, for example `String - ""` or `~"foo"`.
- Invalid or contradictory `RBS::Extended` annotations are diagnostics.
- Losing precision during RBS export should be reportable when users request explanation or strict export mode.

## Implementation Expectations

The implementation should keep parsing, internal type representation, subtyping, consistency, normalization, and RBS erasure as separate concepts. This keeps RBS compatibility stable while leaving room for inference-oriented internal precision.
