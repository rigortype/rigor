# Imported Built-In Types

Rigor imports type ideas from PHPStan, TypeScript, and Python typing only when they have a clear Ruby meaning. Foreign syntax is not preserved for compatibility by default.

This document defines the reserved built-in **names** Rigor uses for refinements and type functions. The internal forms backing these names are catalogued in [rigor-extensions.md](rigor-extensions.md). Operator forms (`~T`, `T - U`, `key_of[T]`, …) are in [type-operators.md](type-operators.md).

## Naming rules

- Reserved built-in **refinement** names use `kebab-case`, such as `non-empty-string`, `positive-int`, and `non-empty-array[T]`.
- Refinement names describe a refined Ruby value domain and are parsed as Rigor-reserved type names, not as Ruby constants or RBS aliases.
- The `-` character is intentional: it is not valid in Ruby constants or RBS alias names, so names such as `non-empty-string` are visually and syntactically marked as Rigor built-ins.
- Rigor MUST NOT add `lower_snake` aliases for refinement names, such as `non_empty_string`. Those names remain available for ordinary RBS type aliases.
- Parameterized **type functions** and type-level operations use `lower_snake` names with square-bracket arguments, such as `key_of[T]`.
- Type functions compute, project, or transform another type or literal set rather than naming a refined value domain directly.
- Type functions avoid `-` because `-` is also the difference operator in Rigor's type syntax; `int_mask[1, 2, 4]` is less ambiguous than `int-mask[1, 2, 4]`.
- Compatibility aliases MUST NOT be accepted unless they solve a concrete migration or readability problem.
- RBS names remain canonical when they already express the concept. `bot` is the bottom type; `never`, `noreturn`, `never-return`, `never-returns`, `no-return`, `Never`, and `NoReturn` MUST NOT be added as initial aliases.
- Integer ranges use Rigor's range notation, such as `Integer[1..10]`. PHPStan-style `int<1, 10>` MUST NOT be added as an alias initially.

## Initial scalar refinements

| Rigor type | Meaning | RBS erasure |
| --- | --- | --- |
| `non-empty-string` | `String` except `""` | `String` |
| `literal-string` | String known to come from source literals and literal-only composition | `String` |
| `numeric-string` | String accepted by Rigor's Ruby numeric-string predicate | `String` |
| `decimal-int-string` | String accepted by Rigor's Ruby decimal-integer-string predicate | `String` |
| `lowercase-string` | String equal to its lowercase normalization | `String` |
| `uppercase-string` | String equal to its uppercase normalization | `String` |
| `non-empty-lowercase-string` | `non-empty-string & lowercase-string` | `String` |
| `non-empty-uppercase-string` | `non-empty-string & uppercase-string` | `String` |
| `non-empty-literal-string` | `non-empty-string & literal-string` | `String` |
| `positive-int` | `Integer` greater than `0` | `Integer` |
| `negative-int` | `Integer` less than `0` | `Integer` |
| `non-positive-int` | `Integer` less than or equal to `0` | `Integer` |
| `non-negative-int` | `Integer` greater than or equal to `0` | `Integer` |
| `non-zero-int` | `Integer` except `0` | `Integer` |

The canonical lowercase string name is `lowercase-string`; `lower-string` MUST NOT be accepted as a separate alias unless a concrete usability problem appears.

## Numeric refinement scope

Integer refinements are deliberately `Integer` refinements, **not** sign refinements for all `Numeric` values. Ruby's numeric classes have different equality, ordering, and promotion behavior, so Rigor MUST NOT generalize `positive-int`, `negative-int`, or `non-zero-int` across nominal numeric boundaries.

Non-integer numeric refinements have separate rules:

- `Float` literal equality and exhaustiveness narrowing are refused by default. `NaN`, infinities, signed zero, and coercion-sensitive comparisons make literal partitions easy to misstate. Rigor MAY retain relational facts from float comparisons, and a future `finite-float` or non-`NaN` proof MAY unlock narrower float-specific refinements.
- `Rational` is exact and ordered, but it is not an `Integer`. Future sign or range facts for `Rational` MUST be Rational-specific and MUST NOT reuse `*-int` names.
- `Complex` does not have a total ordering in Ruby, so positive, negative, and interval refinements MUST NOT apply to `Complex`. Facts about zero-ness, real parts, imaginary parts, or magnitude need explicit predicates or plugin/RBS effects.
- Mixed numeric operations and comparisons follow Ruby method dispatch and `coerce`, not subtype promotion. Refinements MUST NOT automatically cross from `Integer` to `Float`, `Rational`, or another `Numeric` class. When a mixed operation is known, the result type follows the Ruby/RBS operator signature or a trusted plugin fact; otherwise Rigor keeps a relational or dynamic-origin fact and widens conservatively.

Non-integer numeric precision is therefore opt-in through future built-ins, trusted predicates, or plugin and RBS effects, not through silent promotion of `*-int` refinements across nominal numeric boundaries.

## Initial collection and shape refinements

| Rigor type | Meaning | RBS erasure |
| --- | --- | --- |
| `non-empty-array[T]` | `Array[T]` with at least one element | `Array[T]` |
| hash shape with optional keys | Hash with known required and optional keys | RBS record when exact, otherwise `Hash[K, V]` |
| hash shape with extra-key policy | Hash shape that is open, closed, or open only for extra keys of a known value type | RBS record when exact and closed, otherwise `Hash[K, V]` |
| read-only hash shape entry | Key whose value may be read but should not be written through the current reference | Entry mutability marker erased |
| tuple refinements | Fixed or bounded array positions | RBS tuple when exact, otherwise `Array[T]` |
| object shape | Object with known public methods or singleton capabilities | Named interface when available, otherwise `top` or nominal base |

Python `TypedDict` contributes the vocabulary for shape exactness: required and non-required keys, read-only entries, and open, closed, or typed-extra-key policies. Rigor adapts those ideas to Ruby hashes, options hashes, and keyword arguments. A read-only entry is a static write restriction on the current view of the value; it does **not** prove that the underlying Ruby object is frozen.

Rigor MUST NOT initially import PHPStan's `list<T>` and `non-empty-list<T>` as separate surface types. Ruby `Array[T]` already has list-like indexing semantics; `non-empty-array[T]` covers the useful refinement without adding another spelling.

## Initial type functions and operators

| Rigor form | Meaning |
| --- | --- |
| `key_of[T]` | Known keys of a record, hash shape, tuple, or shape-like type |
| `value_of[T]` | Union of known values of a record, hash shape, tuple, or shape-like type |
| `T[K]` | Indexed access into tuple, record, object shape, or generic container metadata |
| `int_mask[1, 2, 4]` | Integers representable by bitwise-or over the listed flags, including `0` |
| `int_mask_of[T]` | Bit mask derived from a finite integer literal union or constant-derived set |

`key_of[T]` is the canonical spelling. Rigor MUST NOT accept both PHPStan-style `key-of<T>` and TypeScript-style `keyof T` unless there is a concrete benefit that outweighs the extra notation.

Diagnostic display rules for these operators (and for the difference and complement operators) are defined in [type-operators.md](type-operators.md).

## Deferred or rejected imports

The following imports are intentionally not provided. Each is recorded so future proposals can refer to a single rule rather than rediscussing the rationale.

- Python `Any` and `object` MUST NOT become Rigor spellings. Rigor uses RBS `untyped` for dynamic boundaries and `top` for the greatest static value type.
- Python `Never` and `NoReturn` MUST NOT become aliases for `bot`. RBS already provides the canonical bottom type.
- Python `Protocol`, `TypedDict`, `Annotated`, `TypeGuard`, `TypeIs`, `Final`, and `ClassVar` MUST NOT become Rigor surface syntax. Their useful ideas map to RBS interfaces, Rigor shape refinements, `%a{...}` annotations, flow effects, and separate symbol or member facts.
- Python `type[C]` MUST NOT be imported as syntax. RBS already uses `singleton(C)` for class objects; a future `instance_type[T]` projection should be designed around Ruby factory APIs.
- Python numeric promotions such as `int` assignable to `float` or `complex` MUST NOT be imported directly. Ruby numeric behavior is modeled from Ruby classes and RBS signatures.
- `class-string`, `interface-string`, `trait-string`, and `enum-string` are deferred. Ruby can pass class and module objects directly, and RBS already has `singleton(C)` for class objects.
- A PHPStan `new`-like type operation remains a future candidate, but it MUST be designed around Ruby class objects rather than class-name strings. For example, a future `instance_type[T]` could project the instance type created by a class object when factory APIs need that precision.
- `non-falsy-string` and `truthy-string` MUST NOT be added because every `String` value is truthy in Ruby.
- `non-decimal-int-string` MUST NOT be a named built-in initially; use `String - decimal-int-string`.
- PHP truthiness-oriented types such as `empty`, `empty-scalar`, `non-empty-scalar`, and `non-empty-mixed` MUST NOT be imported directly. Rigor models Ruby truthiness with `false | nil` flow facts and explicit collection/string refinements.
- `Exclude`, `Extract`, and `NonNullable` MUST NOT be imported as surface aliases initially. Rigor expresses them as `T - U`, `T & U`, and `T - nil`.
- TypeScript utility or mapped type aliases such as `Partial`, `Required`, `Readonly`, `Pick`, `Omit`, `Record`, `Parameters`, `ReturnType`, and `InstanceType` MUST NOT be imported as Rigor surface forms initially.
