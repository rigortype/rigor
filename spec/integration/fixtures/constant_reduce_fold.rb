require "rigor/testing"
include Rigor::Testing

# Constant execution of `reduce` / `inject` over fully-constant
# receivers. When the receiver is a `Constant[Range]` with foldable
# endpoints (or a `Tuple` of `Constant` elements) and the operator is
# an allow-listed pure op, the reduction is executed on the real
# values and the result is a `Constant` — not just the `Integer`
# carrier the ReduceFolding nominal tier produces.

# fact1 — direct constant range, classic factorial accumulator.
fact1 = (1..5).reduce(1, :*)
assert_type("120", fact1)

# fact2 — recursive factorial. The constant-arg recursion unroll
# (ADR-55 slice 1) re-evaluates the body with `n` value-pinned, so a
# constant call folds to the exact value.
def fact2(n)
  if n <= 1
    1
  else
    n * fact2(n - 1)
  end
end
folded2 = fact2(5)
assert_type("120", folded2)

# fact2 over the base case.
empty2 = fact2(0)
assert_type("1", empty2)

# Direct Tuple receiver, no-seed form — the value-folding target this
# change adds: a fully-constant collection folds to its exact value.
fact3 = [1, 2, 3].reduce(:+)
assert_type("6", fact3)

# A non-recursive def body is checked once with its parameter widened
# to `Dynamic[top]` (no per-call constant specialization for the
# non-recursive case), so `(1..n).reduce(1, :*)` surfaces the carrier
# `Integer`, not a value. This documents the boundary of the fold:
# the receiver must be constant AT the fold site.
def range_fact(n) = (1..n).reduce(1, :*)
ranged = range_fact(5)
assert_type("Integer", ranged)

# Empty seeded range folds to the seed.
empty_seed = (1..0).reduce(1, :*)
assert_type("1", empty_seed)

# Float members fold to a Float constant.
float_sum = [1.5, 2.5].reduce(:+)
assert_type("4.0", float_sum)

# Non-constant argument: the carrier (Integer) is the best the engine
# can prove — the constant path declines, the nominal fold answers.
m = rand(100)
nominal = (1..m).reduce(1, :*)
assert_type("Integer", nominal)

# Magnitude cap: `(1..64).reduce(:*)` is a ~296-bit bignum factorial,
# so the constant fold declines and the carrier answers.
big = (1..64).reduce(:*)
assert_type("Integer", big)

# Size cap: an unbounded range never enumerates; the carrier answers.
huge = (1..1_000_000).reduce(:+)
assert_type("Integer", huge)
