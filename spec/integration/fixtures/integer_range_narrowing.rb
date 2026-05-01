require "rigor/testing"
include Rigor::Testing

# Comparison-based narrowing produces PHPStan-style range carriers
# (`positive-int`, `non-negative-int`, `negative-int`,
# `non-positive-int`, `int<a, b>`). Each carrier erases to RBS as
# `Integer` for compatibility but preserves the bound for the
# precise downstream rules below.
n = rand(100)
if n > 0
  assert_type("positive-int", n)
elsif n.zero?
  assert_type("0", n)
else
  assert_type("negative-int", n)
end

# `between?(a, b)` narrows the truthy edge to `int<a, b>` —
# precisely the inclusive range expressed by the call. The
# falsey edge stays the original type because the complement is
# a two-piece domain the lattice does not model.
m = rand(-10..10)
if m.between?(0, 5)
  assert_type("int<0, 5>", m)
end

# Pure arithmetic over Integer literals folds end-to-end through
# the catalog-driven dispatcher. `**`, `&`, `|`, `^`, `<<`, `>>`
# all participate alongside the obvious `+, -, *, /, %`.
power = 5 ** 3
mask = 0xff & 0x0f
shift = 1 << 8
assert_type("125", power)
assert_type("15", mask)
assert_type("256", shift)

# `Integer#abs` on a non-positive range reflects the bounds, so a
# `negative-int` becomes a `positive-int` after `.abs`. Single-
# point ranges collapse back to a `Constant`.
k = rand(100)
if k.negative?
  assert_type("negative-int", k)
  assert_type("positive-int", k.abs)
end
