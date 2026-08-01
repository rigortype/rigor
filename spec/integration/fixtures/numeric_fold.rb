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

# Integer bit-test predicates — pure against a concrete Integer mask
# (0b1010 == 10).
assert_type("true", 0b1010.allbits?(0b1000))
assert_type("false", 0b1010.allbits?(0b0100))
assert_type("true", 0b1010.anybits?(0b0010))
assert_type("true", 0b1010.nobits?(0b0101))

# fdiv — float division, available on both Integer and Float.
assert_type("2.5", 5.fdiv(2))

# Integer#digits — lifts the base-10 place values to a per-position
# Tuple (little-endian: 123 -> [3, 2, 1]).
assert_type("[3, 2, 1]", 123.digits)

# Float#numerator / #denominator — the exact rational decomposition.
assert_type("5", 2.5.numerator)
assert_type("2", 2.5.denominator)

# Float#arg / #angle / #phase — the complex argument of a real:
# 0 for a non-negative receiver, Math::PI for a negative one.
assert_type("0", 2.5.arg)
assert_type("0", 2.5.angle)
assert_type("3.141592653589793", -2.5.phase)

# Integer#rationalize (0-arg) — the Integer sibling of the already-folded
# Float#rationalize / Rational#rationalize. Returns Rational(self, 1).
assert_type("(5/1)", 5.rationalize)

# Integer#abs2 / Float#abs2 — the scalar siblings of the already-folded
# Rational#abs2 / Complex#abs2 (self * self).
assert_type("25", 5.abs2)
assert_type("25", -5.abs2)
assert_type("9.0", 3.0.abs2)

# Non-constant receiver — declines to the RBS-widened class, same as every
# other unary fold's fallback edge. `rand(10)` (unlike a ternary between two
# Integer literals, which stays a foldable Union[Constant, Constant]) types
# as the plain RBS `Integer`, so the receiver genuinely is not a Constant.
assert_type("Integer", rand(10).abs2)
