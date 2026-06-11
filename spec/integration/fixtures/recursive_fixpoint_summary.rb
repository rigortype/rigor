require "rigor/testing"
include Rigor::Testing

# ADR-55 slice 2 — fixpoint recursive return summaries. The in-cycle
# re-entry of a recursive method no longer widens to `Dynamic[top]`;
# instead a Kleene iteration from `bot` computes a signature-free
# return summary, so a recursive contribution carries the method's
# real return type rather than `untyped` contamination.

# A non-constant (`Dynamic`) argument source. `[1, 2, 3].sample`
# returns `Integer` per RBS, but routed through a local `def` it reaches
# the body as a non-value-pinned argument — the path that previously
# joined the recursive call with `Dynamic[top]`.
def some_int = [1, 2, 3].sample

# factorial with a non-constant argument: the recursive `of(n - 1)`
# contribution is now `Integer`, not `Dynamic[top]`. The base case
# stays the literal `Constant[1]`, so the joined return is the precise,
# Dynamic-free `1 | Integer`.
class Factorial
  def of(n)
    n <= 1 ? 1 : n * of(n - 1)
  end
end

assert_type("1 | Integer", Factorial.new.of(some_int))

# A String-building recursion called with a non-constant argument now
# returns `String` cleanly — pre-slice-2 it was `String | Dynamic[top]`
# (`"" | Dynamic[top]` where the recursive contribution was unanalyzed).
class Builder
  def build(n)
    n <= 0 ? "" : "x" + build(n - 1)
  end
end

assert_type("String", Builder.new.build(some_int))

# A method that ONLY recurses never returns: its summary stays `bot`
# (the always-diverging shape) without hanging or blowing the stack.
class Diverge
  def spin(n)
    spin(n + 1)
  end
end

assert_type("bot", Diverge.new.spin(some_int))

# Mutual recursion (the ADR-24 WD5 `module_function` shape) terminates
# — no `SystemStackError`. The cross-signature summary does not fold to
# a precise `bool` here, so it degrades soundly to `Dynamic[top]`
# (today's behaviour); the load-bearing property is termination.
module Parity
  module_function

  def even?(n)
    n == 0 ? true : odd?(n - 1)
  end

  def odd?(n)
    n == 0 ? false : even?(n - 1)
  end
end

assert_type("Dynamic[top]", Parity.even?(some_int))
