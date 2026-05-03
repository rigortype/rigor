require "rigor/testing"
include Rigor::Testing

# v0.0.5+ two-argument fold dispatch.
# `try_fold` previously only handled 0- and 1-arg method
# calls, so `Comparable#between?(min, max)`, the 2-arg form
# of `Comparable#clamp`, and `Integer#pow(exp, mod)` all
# bailed to the RBS tier. The new ternary path consults
# the same per-class / module-aware catalog the binary
# path uses and folds the cartesian product when every
# operand is a `Constant` (or `Union[Constant…]`).

# Comparable#between? — receiver inside the bounds.
assert_type("true", 5.between?(0, 10))

# Comparable#between? — receiver above the upper bound.
assert_type("false", 100.between?(0, 10))

# Comparable#between? — receiver below the lower bound.
assert_type("false", (-5).between?(0, 10))

# Comparable#clamp(min, max) — clamp from below.
assert_type("0", (-5).clamp(0, 10))

# Comparable#clamp(min, max) — clamp from above.
assert_type("10", 100.clamp(0, 10))

# Comparable#clamp(min, max) — already in range.
assert_type("5", 5.clamp(0, 10))

# Integer#pow(exp, mod) — modular exponentiation.
assert_type("4", 100.pow(50, 17))
