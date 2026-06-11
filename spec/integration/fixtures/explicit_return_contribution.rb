require "rigor/testing"
include Rigor::Testing

# ADR-57 slice 2 — explicit `return value` nodes contribute to a user
# method's inferred return type. The tail-only body evaluator previously
# modelled only the fall-through value, so an early `return false` was
# invisible and a predicate helper inferred `Constant[true]` (folding
# `if helper` to always-truthy). The fix joins every reachable explicit
# return (nested `def`/lambda are barriers; block-internal `return`s
# correctly bubble to the enclosing method) with the tail type.

# Non-constant argument sources. A constant `true`/`5` would narrow the
# guard predicate to a known truthy/falsey value, making the early-return
# branch provably dead (correctly pruned, so it would not contribute) —
# defeating the point of these assertions. `[true, false].sample` and
# `[1, 2, 3].sample` keep both branches live.
def some_bool = [true, false].sample
def some_int = [1, 2, 3].sample

# A boolish predicate: early `return false` + tail `true`. Without the
# fix this is `true`; with it, `true | false` (i.e. `bool`).
def predicate(flag)
  return false unless flag

  true
end

assert_type("bool", predicate(some_bool))

# A bare `return` (no argument) contributes `nil`; the tail is a String.
def maybe_label(flag)
  return unless flag

  "label"
end

assert_type('"label"?', maybe_label(some_bool))

# A block-internal `return` returns from the ENCLOSING method in Ruby,
# so its value must join the method return. The block return yields a
# Symbol; the tail yields an Integer.
def scan(item)
  [item].each do |element|
    return :found if element
  end
  0
end

assert_type("0 | :found", scan(some_int))

# A nested `def` is a return barrier: the inner method's `return` belongs
# to it, not the outer. `outer` returns only its own tail (a String); the
# inner `return :inner` (a Symbol) must NOT leak into `outer`'s return.
def outer(_flag)
  def inner(cond)
    return :inner if cond

    99
  end
  "outer"
end

assert_type('"outer"', outer(some_bool))

# A multi-value `return a, b` packs a Tuple in Ruby (`return 1, "x"` is
# `[1, "x"]`). The early multi-value return must contribute its Tuple to
# the method return alongside the tail Tuple. Without the fix the
# multi-value return was dropped entirely (the collector handled only
# single/bare returns), leaving just the tail.
def pair(flag)
  return 1, "x" if flag

  [2, "y"]
end

assert_type('[1, "x"] | [2, "y"]', pair(some_bool))
