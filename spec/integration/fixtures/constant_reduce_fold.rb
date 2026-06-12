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

# A `def` body whose range bound is the parameter: ADR-57 unconditional
# adoption surfaces the per-call `Constant[n]` at the body, and the
# Range literal now folds `(1..n)` to `Constant[Range]` when both bounds
# TYPE as constants (not just literal nodes) — so `(1..n).reduce(1, :*)`
# folds to the exact value through ReduceFolding's constant tier. This
# completes the fact2 chain: bound-type folding feeds the constant
# reduce, which feeds per-call adoption at the call site.
def range_fact(n) = (1..n).reduce(1, :*)
ranged = range_fact(5)
assert_type("120", ranged)
ranged_base = range_fact(0)
assert_type("1", ranged_base)

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

# --- Block-form inject/reduce ---------------------------------------
#
# Part 1 fixed an UNSOUND single-pass accumulator fold (the RBS generic
# `(S) { (S, E) -> S } -> S` bound `S` from one block pass, so
# `(1..5).inject(1) { |a, i| a * i }` typed `int<1, 5>` against a runtime
# of 120 — out of range). Part 2 threads the running constant through
# per-element block evaluation over a fully-constant receiver.

# Block-form factorial: per-element constant threading folds the exact
# value (was the unsound `int<1, 5>`).
block_fact = (1..5).inject(1) { |acc, i| acc * i }
assert_type("120", block_fact)

# No-seed block sum over a constant Tuple (was the unsound `1 | 2 | 3`).
block_sum = [1, 2, 3].inject { |a, b| a + b }
assert_type("6", block_sum)

# The factorial-def chain: per-call adoption surfaces `Constant[n]` at
# the body, the Range bound folds to `Constant[Range]`, and the block
# fold threads the accumulator.
def block_factorial(n) = (1..n).inject(1) { |acc, i| acc * i }
chained = block_factorial(5)
assert_type("120", chained)

# Unknown receiver: the sound Part 1 fixpoint converges the multiply
# accumulator to `1 | Integer`, NEVER a value-bounded interval the
# runtime escapes.
mm = rand(100)
block_nominal = (1..mm).inject(1) { |acc, i| acc * i }
assert_type("1 | Integer", block_nominal)

# Magnitude cap: the 64! product is a ~296-bit bignum, so the constant
# thread declines to the sound nominal fixpoint.
block_big = (1..64).inject(1) { |acc, i| acc * i }
assert_type("Integer", block_big)

# Size cap: a million-element range never enumerates; the nominal
# fixpoint answers.
block_huge = (1..1_000_000).inject(0) { |acc, i| acc + i }
assert_type("Integer", block_huge)

# Side-effect block: a block that BOTH accumulates and mutates a
# captured outer local keeps its fold AND its write-back (the write-back
# runs at the statement level, independent of this return-type fold).
sink = []
side_total = [1, 2, 3].inject(0) do |acc, x|
  sink << x
  acc + x
end
assert_type("6", side_total)
