require "rigor/testing"
include Rigor::Testing

# Static-shape carriers (`Tuple`, `HashShape`) already know their
# size exactly — `[1, 2, 3].size` folds to `Constant[3]`. Wider
# nominal containers (a runtime-built Array, a String returned
# from a method, a Hash assembled procedurally) tighten the
# RBS-declared `Integer` to `non_negative_int`, which is the
# right answer regardless of contents.
def make_words(n)
  Array.new(n) { |i| "w#{i}" }
end

words = make_words(rand(100))
assert_type("non-negative-int", words.size)
assert_type("non-negative-int", words.length)

# String#length / #bytesize on a non-literal source — a method
# call whose return type is `Nominal[String]` rather than a
# folded `Constant`. (A literal String would have folded to a
# `Constant<Integer>` via the unary catalogue, e.g.
# `"hi".length` -> `Constant[2]`.)
text = rand(100).to_s
assert_type("non-negative-int", text.length)
assert_type("non-negative-int", text.bytesize)

# Hash on a non-shape carrier — `Hash.new` returns
# `Nominal[Hash]` rather than the v0.0.7 empty-literal
# `HashShape{}` carrier, so the SIZE_RETURNING_NOMINALS
# tightening (Integer -> non-negative-int) applies.
acc = Hash.new
acc[:a] = 1 if rand < 0.5
assert_type("non-negative-int", acc.size)

# The tightened return type composes with the comparison-based
# narrowing tier: once `size` carries `non_negative_int`, an
# `if size > 0` predicate narrows it to `positive_int`.
n = words.size
if n > 0
  assert_type("positive-int", n)
  assert_type("non-negative-int", n - 1)
end
