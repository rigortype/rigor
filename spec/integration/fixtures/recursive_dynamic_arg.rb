require "rigor/testing"
include Rigor::Testing

# ADR-55 slice 1 — a non-constant argument never takes the unroll
# path. With an `Integer` argument the condition `n <= 1` cannot be
# constant-folded, so both branches are joined; the in-cycle `of`
# self-call keys on `(receiver, method)` exactly as before and stays
# `Dynamic[top]` (WD3 keeps non-`Bot`, non-value-pinned self-call
# returns dynamic inside a body). The result is the pre-ADR-55
# `Constant[1] | Dynamic[top]`, byte-identical to today.
class Factorial
  def of(n)
    n <= 1 ? 1 : n * of(n - 1)
  end
end

f = Factorial.new
x = rand(10)
assert_type("1 | Dynamic[top]", f.of(x))
