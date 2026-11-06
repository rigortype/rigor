# Keep the Nominal narrowing of a guarded gradual value and withhold only argument-type-mismatch on it

- **PR:** [#2920](https://github.com/rigortype/rigor/pull/2920)
- **Issue:** [#2656](https://github.com/rigortype/rigor/issues/2656)
- **Class:** open-choice
- **Precedent:** [ADR-67](../docs/adr/67-parameter-type-inference.md)
- **Decided:** 2026-11-06

## Background

A class guard on an untyped value (`x.is_a?(String)` with `x` a `Dynamic`) narrowed it to the nominal `String`, so passing it to a literal-typed parameter (`("r" | "w")`) reported `call.argument-type-mismatch` on correct code. The issue suggested keeping the gradual facet, `Dynamic[T & C]`. Built that way, it silenced the false positive, but `call.undefined-method` and `call.wrong-arity` do not judge a `Dynamic` receiver. Every guarded untyped value therefore lost those reports (`x.upcase if x.is_a?(Integer)` went silent), 5 true-positive specs failed, and about 25 fixture type assertions changed.

## Options and trade-offs

- (a) `Dynamic[T & C]` on the edge, as the issue suggested. It fixes the false positive but loses the undefined-method and arity true positives on every guarded untyped value.
- (b) Keep the `Nominal` narrowing and mark the narrowed local as gradual-origin; only `call.argument-type-mismatch` reads the mark. It keeps every other rule's reports and the existing type assertions. It withholds every argument-type report on the marked local, including one whose class the parameter can never accept (`num(x) if x.is_a?(String)` with `num: (1 | 2)`).
- (c) Make undefined-method and arity read a `Dynamic[T]` facet. That widens the change to every `Dynamic[T]` value in the program, with unmeasured false-positive cost.

## Decision

(b), as the coordinator ruled. The mark reuses the ADR-58 side-mark set under a new `:gradual_narrowing` kind. ADR-67 WD6b's `:inferred_param` kind is the precedent for a withholding-only mark on that set. The mark follows the `:local` mark's drop-on-write and intersect-on-join policy.

## To undo

Revert #2920: the false positive returns and nothing else changes. To narrow it instead, limit the withholding in `DeclarationSourcedGuard.gradual_narrowed?`'s callers to a parameter that accepts some value of the narrowed class.
