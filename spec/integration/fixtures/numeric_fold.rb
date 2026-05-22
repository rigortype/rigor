require "rigor/testing"
include Rigor::Testing

# Integer / Float mid-priority constant folds (coverage uplift).
# floor / ceil / round / truncate are identities on an Integer
# receiver but still fold to a precise `Constant`.
assert_type("7", 7.floor)
assert_type("7", 7.ceil)
assert_type("7", 7.round)
assert_type("7", 7.truncate)

# Integer#chr — code point to a one-character String.
assert_type('"A"', 65.chr)

# Integer#gcd / #lcm — Integer-only binary arithmetic.
assert_type("4", 12.gcd(8))
assert_type("12", 4.lcm(6))

# fdiv — float division, available on both Integer and Float.
assert_type("2.5", 5.fdiv(2))

# Integer#digits — lifts the base-10 place values to a per-position
# Tuple (little-endian: 123 -> [3, 2, 1]).
assert_type("[3, 2, 1]", 123.digits)
