require "rigor/testing"
include Rigor::Testing

# An array literal lifts to a `Tuple[Constant…]` carrier, so
# positional access (`first`, `last`, `[i]` with a static index)
# returns the precise per-slot type rather than the RBS-widened
# `Integer`.
xs = [10, 20, 30]
first = xs.first
middle = xs[1]
last = xs.last
assert_type("10", first)
assert_type("20", middle)
assert_type("30", last)

# Positional slicing folds to a sub-`Tuple` of the precise per-slot
# types: `drop` / `rotate`.
assert_type("[20, 30]", xs.drop(1))
assert_type("[20, 30, 10]", xs.rotate)
assert_type("[30, 10, 20]", xs.rotate(2))
