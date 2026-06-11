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
# non-nil self_type and an empty guard stack. Pre-fix, the blanket
# `fully_value_pinned?` adoption folded the body to `Constant[42]`;
# the clamp makes adoption inert outside an unroll, so the body's
# self-call result stays `Dynamic[top]` — byte-identical to pre-ADR-55.
assert_type("Dynamic[top]", o.caller)

# (2) The haml `find_else_index` mechanism: a non-local `return` inside
#     an iteration block is a body-evaluator blind spot — the body folds
#     to `nil` (the fallthrough) as if the block-internal `return` never
#     fired. Pre-fix, a self-call to `find` from another method body
#     adopted that WRONG pinned `nil`, mis-folding the caller to always
#     nil (haml's new always-falsey warning). The clamp keeps the
#     self-call result `Dynamic[top]` outside an unroll, masking the
#     blind spot exactly as pre-ADR-55.
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
# `caller_of_find`'s body calls `find` (a value-pinned `nil` result from
# the block-return blind spot) with a non-nil self_type; the clamp keeps
# it `Dynamic[top]` rather than adopting the wrong `nil`.
assert_type("Dynamic[top]", w.caller_of_find)

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
