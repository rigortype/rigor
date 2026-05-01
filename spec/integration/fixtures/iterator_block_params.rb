require "rigor/testing"
include Rigor::Testing

# `Integer#times` yields `0..n-1`, so the block parameter for a
# `Constant<Integer>` receiver carries the precise index range.
5.times do |i|
  assert_type("int<0, 4>", i)
end

# `1.times` yields exactly `0`, so the param collapses to a Constant.
1.times do |i|
  assert_type("0", i)
end

# `Integer#upto` yields the inclusive integer range from receiver
# to argument; the binder pulls the lower bound from the receiver
# and the upper bound from the arg.
3.upto(7) do |i|
  assert_type("int<3, 7>", i)
end

# `Integer#downto` iterates in reverse but the value domain is
# the same; lower bound from the arg, upper bound from the
# receiver.
7.downto(3) do |i|
  assert_type("int<3, 7>", i)
end

# Wider receivers fall back to the non-negative-int half-line —
# the binder keeps the lower bound of 0 (Integer#times never
# yields a negative index) and lets the upper widen.
n = rand(100)
n.times do |i|
  assert_type("non-negative-int", i)
end

# The narrowed block-param threads through the body's expression
# tier as usual, so `i.zero?` etc. fold per the catalogue.
3.times do |i|
  if i.zero?
    assert_type("0", i)
  end
end
