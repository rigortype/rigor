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

# `slice` is an exact alias of `[]`, so it folds the same across the
# index / start-length / Range forms.
assert_type("20", xs.slice(1))
assert_type("30", xs.slice(-1))
assert_type("[20, 30]", xs.slice(1, 2))
assert_type("[10, 20]", xs.slice(0..1))

# Over all-Constant elements, equality is decidable: `uniq` folds to the
# distinct sub-Tuple and `index` / `rindex` to the precise position.
assert_type("[1, 2, 3]", [1, 2, 2, 3].uniq)
assert_type("1", [1, 2, 2, 3].index(2))
assert_type("2", [1, 2, 2, 3].rindex(2))

# Comparable all-Constant elements also fold `minmax` to a 2-slot
# `Tuple[min, max]`, mirroring `Range#minmax`.
assert_type("[10, 30]", xs.minmax)

# The n-arg `min(n)` / `max(n)` forms fold to a Tuple in Ruby's order:
# `min(n)` ascending, `max(n)` descending.
assert_type("[10, 20]", xs.min(2))
assert_type("[30, 20]", xs.max(2))

# Set operations over all-Constant tuples fold to sub-Tuples. Each is
# evaluated with Ruby's own operator, so `eql?` membership (not `==`)
# decides: `[1] & [1.0]` is empty.
assert_type("[20, 30]", xs & [20, 30, 40])
assert_type("[10, 20, 30, 40]", xs | [30, 40])
assert_type("[10, 30]", xs - [20])
assert_type("[]", [1] & [1.0])
assert_type("[20]", xs.intersection([10, 20], [20, 30]))
assert_type("[20]", xs.difference([10], [30]))
assert_type("[10, 20, 30, 40]", xs.union([40]))
assert_type("true", xs.intersect?([30]))
assert_type("false", xs.intersect?([99]))

# `at` folds the single-index form; `one?` counts truthy slots.
assert_type("20", xs.at(1))
assert_type("30", xs.at(-1))
assert_type("false", xs.one?)
assert_type("true", [nil, 1, false].one?)
