require "rigor/testing"
include Rigor::Testing

# ADR-109 WD5 — a comparison of a Float local against a numeric literal narrows its TRUTHY edge to
# the Float range the comparison implies; the falsy edge keeps the entry type, because `!(x > c)`
# is also true of NaN. `nan?` narrows only its falsy edge, `finite?` only its truthy edge.

x = Float(ARGV[0])

if x > 0.0
  assert_type("Float[0.0..]", x)
else
  assert_type("Float", x)
end

if x < 1.0
  assert_type("Float[...1.0]", x)
end

if x <= 1.0
  assert_type("Float[..1.0]", x)
end

# An Integer literal bounds a Float local too; the range is over doubles.
if x >= 0 && x <= 1
  assert_type("Float[0.0..1.0]", x)
end

# A literal on the left is transposed; `1.0 > x` is `x < 1.0`.
if 1.0 > x
  assert_type("Float[...1.0]", x)
end

if x.between?(0.0, 1.0)
  assert_type("Float[0.0..1.0]", x)
else
  assert_type("Float", x)
end

if x.nan?
  assert_type("Float", x)
else
  assert_type("non-nan-float", x)
end

if x.finite?
  assert_type("finite-float", x)
else
  assert_type("Float", x)
end

# A Float literal bound leaves an Integer-rooted local untouched on both edges.
n = ARGV.size
if n > 0.5
  assert_type("non-negative-int", n)
else
  assert_type("non-negative-int", n)
end

# A union narrows member by member: the non-Float member survives, sound but imprecise.
m = x if rand > 0.5
if m && m > 0.0
  assert_type("Float[0.0..]", m)
end

# Narrowing composes with a bounded Float: the tighter upper bound wins, keeping its own end.
if x >= 0.0 && x < 2.0 && x < 1.0
  assert_type("Float[0.0...1.0]", x)
end
