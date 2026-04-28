# RBS-Compatible Types

Rigor supports every type form documented by RBS syntax. This document is the authoritative table mapping RBS forms to Rigor's interpretation and to their RBS erasure.

The exhaustive erasure rules, including the hash-shape erasure algorithm, are in [rbs-erasure.md](rbs-erasure.md). Rigor-only forms that exceed RBS are listed in [rigor-extensions.md](rigor-extensions.md). Reserved built-in refinement names are in [imported-built-in-types.md](imported-built-in-types.md).

## Form table

| RBS form | Rigor interpretation | RBS erasure |
| --- | --- | --- |
| `C`, `C[A]` | Nominal instance type | Same |
| `_I`, `_I[A]` | Interface type | Same |
| `alias`, `alias[A]` | Alias reference, expanded on demand | Same or expanded alias |
| `singleton(C)` | Singleton class object type | Same |
| string, symbol, integer, `true`, `false` literal | Literal singleton type | Same |
| `A \| B` | Union type | Same after erased operands |
| `A & B` | Intersection type | Same after erased operands |
| `T?` | `T \| nil` | Optional syntax when valid, otherwise union |
| `{ key: T }` | Hash record with known keys | Same |
| `[A, B]` | Array tuple with fixed arity | Same |
| type variable | Scoped type variable with bounds and variance | Same |
| `self` | Open-recursive receiver type in self-context | Same when the RBS context allows it |
| `instance` | Current class instance type in classish-context | Same when the RBS context allows it |
| `class` | Current class singleton type in classish-context | Same when the RBS context allows it |
| `bool` | Alias for `true \| false` | `bool` |
| `nil` | The singleton `nil` value | `nil` |
| `untyped` | Dynamic type | `untyped` |
| `top` | Greatest static value type | `top` |
| `bot` | Empty type | `bot` |
| `void` | Return-position no-use result marker | `void` where valid, otherwise `top` with a diagnostic |
| proc type | Callable object type | Same after erased operands |

## Contextual restrictions

`self`, `instance`, `class`, and `void` have context restrictions in RBS. Rigor MAY carry richer contextual information internally, but exported RBS MUST obey those restrictions.

- `self`, `instance`, `class`: valid only in their respective classish or self contexts. Rigor MUST emit them only where RBS accepts them.
- `void`: valid in method and proc return positions and in generic slots that carry it from imported signatures. See [special-types.md](special-types.md) for the value-context rule and the imported-RBS rule.

If an internal type contains one of these markers in an invalid RBS context, the erasure pass MUST rewrite it to the nearest valid conservative type and report the loss of precision. The diagnostic policy for precision loss during export is in [diagnostic-policy.md](diagnostic-policy.md).

## Notes on individual forms

### Optionals

`T?` is normalized to `T | nil` internally (see [normalization.md](normalization.md)). On export, Rigor SHOULD prefer the `T?` syntax when valid; otherwise it falls back to the explicit union.

### Records and tuples

RBS records (`{ key: T }`) and tuples (`[A, B]`) are accepted as exact forms. Rigor's internal hash and array shapes (see [structural-interfaces-and-object-shapes.md](structural-interfaces-and-object-shapes.md)) extend these RBS forms with required/optional/extra-key policies and read-only markers; those extensions erase deterministically (see [rbs-erasure.md](rbs-erasure.md)).

### Type variables

Type variable bounds and declaration-site variance from RBS are preserved. Generic preservation through method bodies — for example inferring `[S < _RewindableStream] (S stream) -> S` when a method returns the same parameter object it received — is a Rigor inference behavior, not a new surface form. See [structural-interfaces-and-object-shapes.md](structural-interfaces-and-object-shapes.md).

### `bool` versus truthiness

`bool` is the literal alias for `true | false`. Ruby truthiness accepts any value, and Rigor models truthiness as a flow predicate, not by widening to `bool`. See [special-types.md](special-types.md) and [control-flow-analysis.md](control-flow-analysis.md).

### `untyped`

`untyped` is preserved at the RBS boundary in both directions. The internal precise representation is `Dynamic[top]`, with full algebra in [value-lattice.md](value-lattice.md). The round-trip from RBS to Rigor and back is exact.
