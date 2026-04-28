# Relations and Certainty

Rigor distinguishes two type relations and a trinary certainty result. Together they describe what the analyzer asks of a type and what it returns to callers.

## Subtyping and gradual consistency

Rigor distinguishes:

- **Subtyping**, written `A <: B`, describes value-set inclusion.
- **Gradual consistency**, written `consistent(A, B)`, describes compatibility when `untyped` participates.

This distinction is required because `untyped` is not simply `top`. `top` is the greatest static value type. `untyped` is the dynamic type: it suppresses precise static checking at a boundary while preserving the fact that precision was lost. See [special-types.md](special-types.md) and [value-lattice.md](value-lattice.md) for the lattice and dynamic-origin algebra.

This specification does not use `~` as the gradual-consistency relation because `~T` is reserved for negative or complement types (see [type-operators.md](type-operators.md)).

### Subtyping properties

- Reflexive: `T <: T` for every type `T`.
- Transitive: if `A <: B` and `B <: C`, then `A <: C`.
- Subtyping is checked against the **static facet** when one is available. For `Dynamic[T]`, subtyping uses `T` as the value-set witness; gradual consistency, not subtyping, governs whether the value can cross a typed boundary.
- The bottom and top identities of the value lattice (`bot <: T`, `T <: top`) hold for every static value type.

### Gradual consistency

Gradual consistency is symmetric in the dynamic direction:

```text
consistent(Dynamic[T], U)
consistent(U, Dynamic[T])
```

Consistency is **not** transitive in the way subtyping is, and it is not a substitute for subtyping. Method availability, member access, and refinement checks use subtyping or structural rules against the static facet. Gradual consistency only explains why a dynamic value may cross a typed boundary.

A complete account of how `Dynamic[T]` participates in unions, intersections, and differences is in [value-lattice.md](value-lattice.md).

## Trinary certainty

Type, reflection, role-conformance, and member-availability queries return one of three results:

- `yes` — proven under the current source, signatures, plugin facts, and configured analyzer assumptions.
- `no` — disproven under the same evidence base.
- `maybe` — every other case.

`yes` and `no` are reserved for results Rigor can treat as proven. `maybe` covers everything else: the analyzer cannot prove the relationship, the answer depends on dynamic behavior, a plugin supplied an uncertain member, or an inference budget was exhausted.

### Method-boundary trust

Rigor MUST trust accepted method signatures at method boundaries. If a parameter or called-method return value has an accepted RBS, rbs-inline, Steep-compatible, generated, or `RBS::Extended` contract, callers analyze through that contract rather than treating every external value as `maybe`. Diagnostics MAY still preserve dynamic provenance when the contract includes `untyped` or came from a plugin.

### `maybe` is not a proof for narrowing

A `maybe` relationship MAY be retained as a weak relational, member-existence, or dynamic-origin fact for diagnostics and later explanation. It MUST NOT refine a value as if the answer were `yes`, and it MUST NOT produce the complementary false-edge fact as if the answer were `no`. Repeated `maybe` evidence remains `maybe`; Rigor MUST NOT promote uncertainty to `yes` merely by count.

### Diagnostic policy is level-dependent

Diagnostic policy is level-dependent, similar in spirit to PHPStan error levels. A permissive level MAY accept a method call or role match that depends on `maybe` evidence without reporting it. Stricter levels MAY report that the proof is uncertain and suggest adding a guard, a signature, generated metadata, or a plugin configuration. The diagnostic identifier scheme that supports this layering is documented in [diagnostic-policy.md](diagnostic-policy.md).

### `maybe` is distinct from incomplete inference

Two distinct concepts MUST NOT be conflated:

- **`maybe`** is a *relational query result*. It applies even when inference is complete: the analyzer simply cannot prove either side under the available evidence.
- **Incomplete inference** is an *analyzer outcome* triggered by a budget cutoff (recursion depth, call-graph width, operator ambiguity, and so on). It produces a `static.*` diagnostic with the cutoff reason and a conservative placeholder type such as `Dynamic[top]`. See [inference-budgets.md](inference-budgets.md).

The two compose. A relational query against a placeholder type MAY return `maybe` because the missing precision blocks a `yes` or `no` answer, but the underlying cause is the cutoff. The diagnostic MUST identify the cutoff as such. Implementations MUST NOT collapse "stopped early" into a relational `maybe` that hides the cutoff from users.
