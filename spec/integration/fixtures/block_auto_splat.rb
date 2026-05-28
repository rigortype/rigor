require "rigor/testing"
include Rigor::Testing

# Ruby blocks auto-splat a single yielded Tuple-shaped value when
# the block declares more than one required positional parameter.
# `Hash#each` yields `[key, value]` as a single arg; a `|k, v|`
# block sees `k = key, v = value`. Pre-fix the binder gave
# `k = [:a | :b, 1 | 2]` (whole Tuple) and `v = Dynamic[Top]`.

{ a: 1, b: 2 }.each do |k, v|
  assert_type(":a | :b", k)
  assert_type("1 | 2", v)
end

# Single-param form: no splat — `pair` keeps the Tuple shape.
{ a: 1, b: 2 }.each do |pair|
  assert_type("[:a | :b, 1 | 2]", pair)
end

# Excess block params get Dynamic[Top] (Ruby would set them nil
# at runtime; we deliberately stay loose).
{ a: 1, b: 2 }.each do |k, v, extra|
  assert_type(":a | :b", k)
  assert_type("1 | 2", v)
  assert_type("Dynamic[top]", extra)
end
