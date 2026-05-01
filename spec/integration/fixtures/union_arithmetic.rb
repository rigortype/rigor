require "rigor/testing"
include Rigor::Testing

# `Union[Constant<Integer>…]` participates in arithmetic
# end-to-end. The analyzer runs the real Ruby operator on every
# (receiver, arg) pair in the cartesian product, deduplicates,
# and rebuilds a `Union[Constant…]` from the survivors. Two
# cardinality caps keep the fold bounded:
#
# - `UNION_FOLD_INPUT_LIMIT = 32` — bails before invocation
#   when the cartesian product is too large.
# - `UNION_FOLD_OUTPUT_LIMIT = 8` — falls back to the bounding
#   `IntegerRange` (or `nil` for non-Integer mixes) when the
#   deduped result exceeds this cap.

# Cartesian fold over two small unions. `1+2 = 3` and `2+2 = 4`
# are distinct; `1+3` and `2+2` both equal 4 and dedupe.
a = [1, 2].sample
b = [2, 3].sample
assert_type("3 | 4 | 5", a + b)

# Union × Constant collapses element-wise multiplication. `0`
# absorbs every receiver value, so the whole fold collapses
# back to a single `Constant[0]`.
mask = [10, 20, 30].sample * 0
assert_type("0", mask)

# Comparison over a Union receiver collapses naturally to
# `Union[true, false]` — the codomain caps the result tighter
# than the input cardinality would suggest.
parity = [1, 2, 3].sample
assert_type("false | true", parity > 2)

# When the cartesian fold exceeds the output cap and every
# result is an Integer, the analyzer widens to the bounding
# `IntegerRange`. Here `[1..5].sample + [10, 20, 30, 40, 50].sample`
# has 5 × 5 = 25 distinct sums (well over the cap), so the
# analyzer surfaces `int<11, 55>` instead of giving up.
spread = [1, 2, 3, 4, 5].sample + [10, 20, 30, 40, 50].sample
assert_type("int<11, 55>", spread)
