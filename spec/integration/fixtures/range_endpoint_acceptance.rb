require "rigor/testing"
include Rigor::Testing

# Issues #833 / #834 — a Range literal argument is read through its ENDPOINTS. A `Range[T]`
# parameter no longer accepts a literal whose endpoints T rejects, so overload selection stops
# pinning whichever `Range[…]` arm comes first in declaration order; and a `Range[A]` parameter
# binds `A` from those same endpoints, so `Comparable#clamp` keeps the receiver's class instead of
# failing soft.

# The folds that answer ahead of the RBS tier are untouched by either half.
assert_type("Float[1.0..2.0]", Random.rand(1.0..2.0))
assert_type("Integer[1..6]", rand(1..6))

# The RBS tier with no fold ahead of it — the folds cover the `Random` singleton, not an instance.
# `Random#rand` declares `(Integer | Range[Integer]) -> Integer` ahead of `(Float | Range[Float]) ->
# Float`, so before #833 a Float literal took the Integer arm purely by declaration order.
g = Random.new
assert_type("Float", g.rand(1.0..2.0))
assert_type("Float", g.rand(0.0...1.0))
assert_type("Integer", g.rand(1..6))

# `Range[Integer?]` is core RBS's spelling of the slicing parameter, and it must keep accepting both
# the Integer-endpoint and the endless literals real code passes it.
assert_type("[1, 2]", [1, 2, 3][0..1])
assert_type('"abc"', "abc"[0..])
assert_type("Array[String]?", ARGV[0..1])
assert_type("Array[String]?", ARGV[0..])

# `Comparable#clamp: [A] (Range[A]) -> (self | A)` on a plain Integer receiver — no fold applies,
# because an unbounded Integer has no bracket of its own to intersect. Before #834 the unbound `A`
# degraded to `Dynamic[top]` and the whole call answered `Dynamic[top] | Integer`.
i = Integer(ARGV[0])
assert_type("Integer", i.clamp(1..9))
assert_type("Integer", i.clamp(1..))
