require "rigor/testing"
include Rigor::Testing

# ADR-55 slice 1 — fueled constant-arg recursion unroll. When every
# argument of a recursive call is value-pinned (a `Constant`, or a
# `Tuple` of such), the recursion guard key extends to include the
# argument *values* so distinct constant frames may recurse under a
# hard fuel budget (32 frames per outermost entry). The folded
# in-cycle result, being a concrete value, is adopted even inside a
# method body — it is FP-neutral by construction.
class Factorial
  def of(n)
    n <= 1 ? 1 : n * of(n - 1)
  end
end

# String-building recursion folds to the built constant string.
class Stars
  def render(n)
    n <= 0 ? "" : "*" + render(n - 1)
  end
end

# Mutual recursion with constant args terminates and folds.
class Parity
  def even?(n)
    n == 0 ? true : odd?(n - 1)
  end

  def odd?(n)
    n == 0 ? false : even?(n - 1)
  end
end

f = Factorial.new
assert_type("120", f.of(5))

# Fuel exhaustion (100 > 32 frames) degrades gracefully to today's
# widened result — no SystemStackError, no hang.
assert_type("Integer", f.of(100))

s = Stars.new
assert_type('"***"', s.render(3))

p = Parity.new
assert_type("true", p.even?(4))
assert_type("true", p.odd?(3))
