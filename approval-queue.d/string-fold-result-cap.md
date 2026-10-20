# A String fold past the byte limit declines the whole fold instead of widening to Nominal[String]

- **PR:** [#2247](https://github.com/rigortype/rigor/pull/2247)
- **Issue:** [#2125](https://github.com/rigortype/rigor/issues/2125)
- **Class:** open-choice
- **Precedent:** [#2115](https://github.com/rigortype/rigor/issues/2115)
- **Decided:** 2026-10-21

## Background

#2125 caps every String-producing constant fold at `STRING_FOLD_BYTE_LIMIT` (4096 bytes). The issue asked that a result past the limit widen to `Nominal[String]` rather than fall through to "a less precise RBS answer", by analogy with #2115, where a number past `INTEGER_FOLD_BIT_LIMIT` widens to its class because RBS `Integer#**` returns `Numeric`. For Strings the fall-through is not less precise: the next tier is `LiteralStringFolding`, which answers `literal-string` (its own doc names "the multiplication exceeds the constant-fold size cap" as a case it exists for), and below it RBS answers `String` for every String-producing method the fold covers (`%`, `*`, `+`, `center` / `ljust` / `rjust`, `sub` / `gsub`, `tr`, `dump`, `Integer#to_s`).

## Options and trade-offs

- Widen to `Nominal[String]`, as the issue suggests. It bypasses `LiteralStringFolding`, so `"x" * 5000` would lose the `literal-string & non-empty-string` it has today, a precision loss on the existing `*` / `+` / pad caps.
- Decline the whole fold and let the next tier answer. It keeps today's answer for the existing caps and gives the new caps the same one; the answer is never wider than `String`.

Either way the oversized member of a union receiver can no longer be dropped silently: before this change `(c ? "a" : "b" * 3000) * 2` folded to `"aa"`.

## Decision

Decline the whole fold. It matches what the existing `*` / `+` / pad caps already did (their spec comment says the value falls through to the RBS `String` envelope) and the documented role of `LiteralStringFolding`, and it never answers less than `Nominal[String]`. The `Integer#to_s(base)` operand precheck the issue listed was left out: its receiver is already bounded by `INTEGER_FOLD_BIT_LIMIT`, so its rendering is at most 13 KB and the result gate covers it.

## To undo

Make `OVERSIZED_STRING` a `WidenedResult.new("String")` in `ConstantFolding`, so `build_constant_type` unions `Nominal[String]` in; the existing `*` / `+` / pad caps and their specs would then answer `String` instead of `literal-string`.
