# Special Types

Rigor distinguishes several special types that have specific semantic roles and are not interchangeable. The lattice in which they live is defined in [value-lattice.md](value-lattice.md).

## `top`

`top` is the greatest type for any Ruby value. It is useful when a value exists but Rigor has no useful static structure for it.

Using a value of type `top` is still checked. A method call on `top` MUST be accepted only when the method is known to be available for every possible inhabitant, or when a plugin supplies a stronger fact.

`top` plays the role of TypeScript's `unknown` for the safe-top axis: a value of type `top` can hold any Ruby value, but the analyzer requires a guard, signature, or plugin fact before it can be used. Diagnostics for unguarded calls on `top` belong to the `static.*` family (see [diagnostic-policy.md](diagnostic-policy.md)).

## `bot`

`bot` is the empty type. It appears in unreachable branches, methods that always raise, exits, failed pattern matches, and contradictory refinements.

`bot` is useful for control-flow analysis because joining `bot` with a real branch leaves the real branch unchanged: `T | bot = T`.

For return contracts, `bot` satisfies every result contract because no normal value is produced. A method body that always raises, exits, or loops forever is therefore compatible with a `void` return contract. The reverse is not true: a `void` result is **not** a proof of non-returning control flow and does **not** satisfy a `bot` return contract.

## `untyped` and `Dynamic[T]`

`untyped` is the dynamic type. It is consistent with every type:

```text
consistent(untyped, T)
consistent(T, untyped)
```

Rigor's internal representation is more precise:

```text
untyped = Dynamic[top]
```

`Dynamic[T]` combines two facts:

- the value crossed a gradual boundary or otherwise came from unchecked information;
- the current control-flow analysis can still prove the static facet `T`.

`Dynamic[T]` is **not** surface RBS syntax and MUST NOT be accepted as an ordinary user-authored type. It is an implementation form. The full algebra (joins, intersections, differences, generic-slot preservation) is in [value-lattice.md](value-lattice.md).

### Subtyping versus consistency

Subtyping and method availability are checked against the static facet `T` when Rigor has one. Gradual consistency, not subtyping, is what allows a dynamic value to cross a typed boundary. See [relations-and-certainty.md](relations-and-certainty.md).

### Operations on raw `Dynamic[top]`

Operations on raw `Dynamic[top]` MUST NOT create false precision. A method call on raw `untyped` returns `Dynamic[top]` unless Rigor has an explicit refinement, signature, or plugin-provided rule. Assigning a dynamic-origin value to a precise type is allowed at a gradual boundary, but Rigor MUST retain enough provenance to explain that the value passed through unchecked code.

### Dynamic-origin sources

Rigor SHOULD distinguish dynamic-origin sources for diagnostics, even though the type relation is the same for all of them:

- explicit `untyped` in RBS, rbs-inline, or Steep-compatible annotations;
- missing external signatures or implicit unknown library facts;
- analyzer limits, failed inference, or plugin-declared dynamic behavior.

Diagnostics MAY use these distinctions to explain whether a `Dynamic[T]` came from a deliberate gradual boundary or from a missing signature.

### Strict modes

Strict dynamic modes MAY report dynamic-to-precise assignments, arguments, returns, and generic-slot leaks such as `Array[Dynamic[top]]`. Strict static modes MAY additionally report method calls or branch proofs whose safety depends on dynamic-origin facts rather than checked static facts.

## `void`

`void` is **not** an ordinary value type in Rigor. It is a result marker for expressions whose return value should not be used.

RBS treats `void`, `boolish`, and `top` equivalently for many type-system purposes. Rigor keeps `void` distinct internally so it can diagnose value use:

```ruby
result = puts("hello")
# `puts` returns void; assigning or sending methods to the value is suspicious.
```

### Rules

- `void` is valid in method and proc return positions.
- A `bot` implementation path is compatible with `void`; a `void` implementation path is not compatible with `bot`.
- `void | bot` normalizes to `void` in result summaries because the `bot` path contributes no normal value.
- `void` is valid as a generic argument, block parameter, or callback return only when preserving an existing RBS signature.
- Rigor SHOULD NOT infer or author new `void` slots inside ordinary unions, optionals, records, tuples, or parameter types.
- When imported RBS places `void` in a generic slot, Rigor MUST preserve the slot. Reading from that slot produces a `void` result marker, and using that result follows the ordinary `void` value-context rule.

### Statement context vs value context

- In statement context, a `void` result is accepted.
- In value context, a `void` result MUST produce a primary "use of void value" diagnostic and is materialized as `top` for downstream recovery.
- Recovery from a `void` value SHOULD suppress immediate cascading diagnostics such as "method on `top`" for the same expression unless the user has requested cascading output.

The recovery rule means a `void` value reaches `top`, not a stricter or weaker substitute. Rigor's contribution on top of the RBS rule is to record that the value reached the position by recovery from `void` and to surface that as a primary diagnostic, so the analyzer can explain *why* a `top` appeared and the user can fix the call site rather than learning to live with a generic `top`.

## `nil`, `NilClass`, and optional types

`nil` is the singleton nil value. `T?` is normalized to `T | nil` (see [normalization.md](normalization.md)).

`NilClass` is a nominal RBS type, but Rigor SHOULD prefer the singleton `nil` internally whenever it can prove the exact value. Export SHOULD prefer `nil` for singleton nil and preserve `NilClass` only when it came from an explicit external signature.

Optional-key absence in hash shapes does **not** add `nil` to the value type. Absence is not a stored value. Hash-shape erasure rules are in [rbs-erasure.md](rbs-erasure.md).

## `bool`, truthiness, and `boolish`

`bool` is `true | false`.

Ruby conditionals accept any value as a truth value: only `false` and `nil` are falsey. Rigor models this as a flow-sensitive predicate over types (see [control-flow-analysis.md](control-flow-analysis.md)), not by widening every condition to `bool`.

RBS `boolish` is an alias of `top`. Rigor SHOULD erase truthiness-accepting callback return types to `boolish` when matching an existing RBS signature, but internally it SHOULD retain the actual return type when possible.
