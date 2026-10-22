# The inferred-parameter guard follows array and hash literals and same-method ivar writes, not cross-method ivars

- **PR:** [#2279](https://github.com/rigortype/rigor/pull/2279)
- **Issue:** [#2189](https://github.com/rigortype/rigor/issues/2189)
- **Class:** open-choice
- **Precedent:** [ADR-67](../docs/adr/67-parameter-type-inference.md)
- **Decided:** 2026-10-22

## Background

Under `parameter_inference:`, ADR-67 WD6b makes the negative rules decline on an inferred parameter,
because its type is a lower bound from the call sites the run saw. Issue #2189 found three
derivations that escaped the guard: an array literal element read back, a hash literal value read
back, and an ivar written from the parameter. The issue left three things open: how wide the
literal rule is, how the ivar carries the mark, and what happens when an ivar is written in one
method and read in another.

## Options and trade-offs

- **Literal width.** (a) Only element reads (`first`, `[]`, `fetch`, …) on a literal holding the
  parameter decline. (b) Any call on such a literal declines. (a) keeps diagnostics like
  `[name].no_such_method` but needs a list of element-reading methods that will be incomplete.
  (b) can only lose a diagnostic, and only under `parameter_inference:`.
- **Ivar carrier.** (a) A new mark kind for ivars. (b) The existing `:inferred_param` kind under
  the ivar's `@`-prefixed name, which no local can spell. (a) would need its own union-at-join and
  stickiness code. (b) reuses both unchanged.
- **Cross-method ivars.** (a) Record at class level which ivars a method wrote from an inferred
  parameter, and mark them in sibling methods. (b) Keep the mark method-local. Today the class-ivar
  census types the write without the inference seed, so a sibling's read is `Dynamic` and never
  fires. (a) would add machinery for a case that does not produce a false positive.

## Decision

Option (b) on all three. Any call on a literal holding the parameter declines. The ivar reuses the
`:inferred_param` kind. The mark stays method-local. ADR-67 WD6b's rule is to decline on anything
derived from a lower bound, and a wider decline only withholds diagnostics, which is the FP-safe
direction. A guard example
(`spec/rigor/analysis/parameter_inference_check_walk_spec.rb`, "does not report a sibling method's
read …") fails if the census ever starts reading the inference seed, and option (a) for
cross-method ivars becomes necessary then. `@x ||= name`, operator writes, multiple assignment and
splats in literals do not stamp the mark: #2189 did not name them.

Accepted losses, all under `parameter_inference:` only, all in the withholding direction:

- `InferredParamGuard.rooted?` is shared with `AlwaysTruthyConditionCollector`, so
  `if {a: name}.key?(:a)` no longer reports `flow.always-truthy-condition`.
- A parameter that appears only as a hash key roots the whole literal, so `{name => 1}[1].upcase`
  declines although the value read back is the literal `1`.
- The ivar mark is sticky like the local one: only a plain `@x = rhs` clears it. After
  `@x = name`, a rebind through multiple assignment (`@x, @y = 5, 6`), `rescue => @x` or
  `for @x in [5]` keeps the mark, so a later true positive on `@x` is withheld.

## To undo

Narrow the literal arm of `InferredParamGuard.literal_rooted?`. Or remove
`StatementEvaluator#mark_inferred_param_ivar` and the `InstanceVariableReadNode` branch in
`InferredParamGuard.rooted?`. Then drop the matching examples. Nothing else depends on the mark.
