# RBS Erasure

RBS erasure converts an internal Rigor type to a valid RBS type. The Rigor→RBS direction is **not** lossless: erasure MAY collapse refinements, literal unions, shapes, and dynamic-origin provenance. Erasure MUST NOT produce a narrower type than Rigor proved; it MAY produce a wider one.

This document defines the general erasure rules and the hash-shape erasure algorithm. The internal forms that erasure consumes are catalogued in [rigor-extensions.md](rigor-extensions.md).

## General rules

- Exact RBS types erase to themselves.
- Refined types erase to their unrefined base.
- Unsupported literal kinds erase to their nominal class.
- Integer ranges erase to `Integer`.
- Complement and difference refinements erase to their current domain type.
- Hash-shape openness, extra-key, and read-only markers are erased by the hash-shape erasure algorithm below.
- Object shapes erase to a matching named interface when one exists, otherwise a conservative nominal or `top`.
- Dynamic-origin wrappers erase to `untyped` when exported as unchecked-boundary types. When a value has already been checked against a non-dynamic contract, the contract type is exported and the dynamic marker is not represented in RBS.
- Invalid-context `void`, `self`, `instance`, or `class` forms are rewritten to valid conservative RBS and reported as precision loss (see [rbs-compatible-types.md](rbs-compatible-types.md) for context restrictions).

Erasure is conservative: if `erase(T) = R`, then every value accepted by `T` MUST be accepted by `R`.

## Hash-shape erasure

Hash shapes carry more information than RBS records and `Hash[K, V]` can express: required keys, optional keys, read-only entries, open or closed extra-key policy, key presence facts, dynamic-origin provenance, and stability. RBS erasure MUST lose that information deterministically and conservatively.

### Exact closed shapes

Exact closed shapes erase to RBS records when every key can be represented by RBS record syntax:

- Required entries become required record fields.
- Optional entries become optional record fields when RBS can spell the optional key.
- Entry value types erase recursively.
- Read-only, provenance, stability, and key-presence markers are erased.
- Missing optional keys do not add `nil` to the value type. Absence is not a stored value.

Examples:

```text
closed { a: 1, b: "str" }
  => { a: 1, b: "str" }

closed { a: Integer, ?b: String }
  => { a: Integer, ?b: String }
```

### Fallback to `Hash[K, V]`

If the shape cannot be represented as an exact RBS record, it erases to `Hash[K, V]`.

#### Reconstructing the key type `K`

The key type `K` is reconstructed from:

- known literal keys, kept as a literal union while the set is finite and within the export budget;
- widened nominal key classes when the literal-key set is too large for readable RBS;
- the declared extra-key bound for open shapes with typed extra keys;
- `top` for statically open shapes with unknown extra keys;
- `untyped` for dynamic-origin extra keys.

#### Reconstructing the value type `V`

The value type `V` is reconstructed from:

- values of all known required entries;
- values of known optional entries, because they may be present;
- the declared extra-value bound for open shapes with typed extra keys;
- `top` for statically open shapes with unknown extra values;
- `untyped` for dynamic-origin extra values.

Optional-key absence does not contribute `nil` to `V` unless the entry value type itself includes `nil`.

### Empty closed records

An exact empty closed record erases to `{}`. If a target RBS version or output mode cannot preserve an empty record, the fallback is `Hash[bot, bot]`.

### Open shapes with extra-value bounds

For open shapes, the extra-value bound MUST be used when known. Rigor MUST NOT use only the current known value union for unknown extra keys, because an unseen extra key may hold a value unrelated to the observed entries.

Examples:

```text
open { a: 1, b: "str", **String => bool }
  => Hash[:a | :b | String, 1 | "str" | bool]

open { a: 1, b: "str", **unknown }
  => Hash[top, top]

dynamic-open { a: 1, **untyped }
  => Hash[untyped, untyped]
```

### Budget-driven widening

If literal-key or literal-value unions exceed the export budget, Rigor MUST widen them to nominal bases deterministically, such as `Hash[Symbol, Integer | String]`. Losing closedness, optional-key precision, read-only status, or literal precision SHOULD be reportable in strict export or explanation mode.

The literal-key and literal-value unions have **separate** budgets because keys carry more identifier-like meaning than values do:

- `budgets.hash_erasure_keys` (default 16, range 1–256) controls the literal-key union.
- `budgets.hash_erasure_values` (default 8, range 1–256) controls the literal-value union.

Both are configurable in `.rigor.yml`. See [inference-budgets.md](inference-budgets.md) for the full budget table.

When one budget is exceeded, only that axis widens to the nearest nominal base; the other axis remains a literal union if it still fits. Widening is deterministic:

- the widened nominal base for keys is the least common nominal class among the literal keys (for example `Symbol`, `String`, `Integer`);
- the widened nominal base for values is the least common nominal class or `top` when the values do not share a useful base.

Rigor MUST explain a budget-driven widening as `+N more` in the diagnostic, with full details available through `rigor explain`. The omission contract is in [type-operators.md](type-operators.md).
