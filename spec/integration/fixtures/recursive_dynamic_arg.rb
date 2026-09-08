require "rigor/testing"
include Rigor::Testing

# ADR-55 slice 1 — a non-constant argument never takes the unroll
# path. With an `Integer` argument the condition `n <= 1` cannot be
# constant-folded, so both branches are joined; the in-cycle `of`
# self-call keys on `(receiver, method)` exactly as before and stays
# `Dynamic[top]` (WD3 keeps non-`Bot`, non-value-pinned self-call
# returns dynamic inside a body).
#
# The multiplication itself no longer inherits that dynamism: the
# `n <= 1` guard narrows the falsy-branch receiver to an IntegerRange
# (`positive-int`, excluding 0 and 1), and since #842 that carrier
# reaches RBS dispatch like any other Integer, so `Integer#*` resolves
# against the Dynamic argument through the ordinary gradual-typing
# path (ADR-5) instead of declining outright. Pre-#842 the join was
# `Constant[1] | Dynamic[top]`.
class Factorial
  def of(n)
    n <= 1 ? 1 : n * of(n - 1)
  end
end

f = Factorial.new
x = rand(10)
assert_type("1 | Integer", f.of(x))
