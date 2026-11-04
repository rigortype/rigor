# A block-pass counts as possibly nil unless its value provably excludes nil

- **PR:** [#2815](https://github.com/rigortype/rigor/pull/2815)
- **Issue:** [#2802](https://github.com/rigortype/rigor/issues/2802)
- **Class:** open-choice
- **Precedent:** [ADR-130](../docs/adr/130-interface-typed-values-dispatch-under-untyped-parity.md)
- **Decided:** 2026-11-05

## Background

ADR-130 WD3 lets a call on a `Rigor::Plugin` interface value answer through a declared member only when an overload takes the call's shape. A block-pass `&blk` whose value may be `nil` may run the call block-less, so the call answers only when both the block-ful and the block-less shape are taken and their returns agree. The ADR worded the trigger as "`expr` is a nil-bearing union or `Dynamic`". The first review of #2815 found that a `top` or `Object` value, which may be `nil` at runtime, fell outside that wording: `x.overloaded(&blk)` with `blk : top` against `() -> Integer | () { (Integer) -> void } -> String` read `String`.

## Options and trade-offs

- Keep the literal wording: a `top`, `Object`, `BasicObject` or `Kernel` value takes only the block shape, and the call answers the block overload's return although the runtime may take the other.
- Read the rule as "any value not provably non-nil": only a non-nil literal, an instance of a class `nil` is not (a `Proc`, a `Method`), a class object or a shape takes the block shape alone; `&:sym` stays non-nil. This costs precision only on calls whose block-pass value the analysis cannot prove non-nil, where the call now reads `Dynamic[top]` as it does on master.

## Decision

The second. It is what WD3's rule is for (the call may be block-less at runtime), it can only decline where the literal reading answered, and a decline reads as master reads. ADR-130's sentence is amended to "any value not provably non-nil", and `structural-interfaces-and-object-shapes.md` § "Interface-typed values" says the same.

## To undo

Restore the union-or-`Dynamic` test in `InterfaceShape.nilable_block_pass?` (`never_nil?`), drop the `top` / `Object` lines of `spec/integration/fixtures/interface_parity/dispatch_shapes`, and revert the ADR and spec sentences. Nothing else depends on it.
