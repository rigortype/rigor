require "rigor/testing"
include Rigor::Testing

# `Array#inspect` / `#to_s` fold to a `Constant[String]` when every element is `Constant`, by
# reconstructing the real Ruby Array and calling ITS `inspect` — so the format (Ruby 4.0's
# `[1, "a"]`) is matched rather than re-derived (#121).
xs = [1, "a"]
assert_type('"[1, \"a\"]"', xs.inspect)
assert_type('"[1, \"a\"]"', xs.to_s)
assert_type('"[]"', [].inspect)

# `Hash#inspect` / `#to_s` fold the same way for a CLOSED shape with no optional keys, matching
# Ruby 4.0's `{a: 1}` symbol-key format.
h = { a: 1, b: "x" }
assert_type('"{a: 1, b: \"x\"}"', h.inspect)
assert_type('"{a: 1, b: \"x\"}"', h.to_s)
assert_type('"{}"', {}.inspect)

# `Array#*` with a `Constant[String]` argument is `#join`'s alias. (A literal-array receiver here
# would be autocorrected to `#join` by RuboCop's `Style/ArrayJoin`, defeating the point of the
# assertion, so the receiver is a variable.)
ys = [1, 2]
assert_type('"1-2"', ys * "-")

# `Array#*` with a `Constant[Integer]` argument repeats the receiver's elements.
assert_type("[1, 2, 1, 2]", [1, 2] * 2)
assert_type("[]", [1, 2] * 0)

# A non-constant element declines `#inspect` (falls through to the RBS-declared `String` answer);
# a non-constant `*` multiplier declines the join-alias / repetition fold the same way (falls
# through to the RBS/alias-pass answer) — Ruby's own `Array#*` needs a REAL Constant multiplier to
# fold deterministically.
opaque = "runtime#{rand(2)}"
mixed = [1, opaque]
assert_type("String", mixed.inspect)

# The handler itself declines (a non-Constant multiplier), but the RBS/alias-pass fallback still
# answers a decent `Array[1 | 2]` from the Tuple's own element-union erasure — not a wrong wide
# type, so there is nothing for this fold to improve on here.
count = rand(3)
assert_type("Array[1 | 2]", [1, 2] * count)
