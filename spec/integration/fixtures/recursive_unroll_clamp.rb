require "rigor/testing"
include Rigor::Testing

# ADR-55 WD1 clamp (corpus-regression guard, 2026-06-11).
#
# Two confinements of the constant-arg unroll's precision envelope:
#
# (1) Value-pinned self-call adoption is INERT outside an unroll. In a
#     method body (non-nil self_type, empty guard stack) a self-call
#     whose return folds to a constant is NOT adopted — it stays
#     `Dynamic[top]` exactly as before ADR-55, because the main check
#     walk's body evaluator has known blind spots whose wrong pinned
#     values were previously masked by the Dynamic gate.
class Outside
  def leaf
    42
  end

  def caller
    # `leaf` resolves to Constant[42] but, outside an unroll, adoption
    # is inert: the self-call result stays Dynamic[top].
    leaf
  end
end

o = Outside.new
# Called from the top level (self_type nil) the unroll-independent
# adoption path is unaffected and the precise value still surfaces.
assert_type("42", o.leaf)

# `caller`'s body calls `leaf` (a value-pinned self-call) with a
# non-nil self_type. ADR-57 opened the self-call return-adoption gate
# permanently (2026-06-12), so the body now adopts `leaf`'s precise
# `Constant[42]` return. The body-evaluator blind spots that historically
# made in-body adoption unsafe (and kept this `Dynamic[top]` under the old
# ADR-55 clamp) were fixed at their root across ADR-55/56/57 — the block-
# internal `return` collector exercised in case (2) is one of them.
assert_type("42", o.caller)

# (2) The haml `find_else_index` mechanism: a non-local `return` inside an
#     iteration block exits the ENCLOSING method. ADR-57 slice 1's explicit-
#     return sink now collects those block-internal returns, so `find`'s real
#     return is `1 | 2 | 3 | nil` (the three early returns joined with the
#     `nil` fallthrough) — not the WRONG pinned `nil` the old tail-only
#     evaluator inferred. With the blind spot fixed, the now-open gate adopts
#     the CORRECT precise return at the caller.
class Walk
  def find(n)
    [1, 2, 3].each do |i|
      return i if i == n
    end
    nil
  end

  def caller_of_find
    find(2)
  end
end

w = Walk.new
# `caller_of_find`'s body adopts `find`'s correct `1 | 2 | 3 | nil` return.
assert_type("1 | 2 | 3 | nil", w.caller_of_find)

# (3) Governing-rule clamp inside the unroll. `go`'s in-cycle frames
#     fold to a genuinely NON-pinned union (`1 | "s"`); the constant-arg
#     unroll may only ever surface a fully value-pinned result, so each
#     non-outermost re-entry whose body is non-pinned is clamped back to
#     the plain guard's `untyped`. The recursion degrades soundly to the
#     widened union rather than leaking a precise-but-unguarded type, and
#     never blows the stack.
class Rec
  def go(n)
    if n <= 0
      1
    else
      (cond ? go(n - 1) : "s")
    end
  end

  def cond
    [true, false].sample
  end
end

assert_type("\"s\" | Dynamic[top]", Rec.new.go(3))
