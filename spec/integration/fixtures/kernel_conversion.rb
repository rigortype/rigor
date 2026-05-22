require "rigor/testing"
include Rigor::Testing

# Kernel numeric-conversion folds. Integer / Float / Rational /
# Complex are all core, so a flat fixture suffices.

# Integer() — constant string, explicit base, and numeric truncation.
assert_type("42", Integer("42"))
assert_type("255", Integer("ff", 16))
assert_type("3", Integer(3.7))

# Float() — constant string and numeric widening.
assert_type("3.14", Float("3.14"))
assert_type("42.0", Float(42))

# Rational() / Complex() — numeric constructors (already folded,
# exercised here for the cohesive conversion picture).
assert_type("(1/2)", Rational(1, 2))
assert_type("(1+2i)", Complex(1, 2))

# An unparseable string declines the fold; the RBS tier answers
# with the widened Integer / Float envelope.
assert_type("Integer", Integer("not a number"))
assert_type("Float", Float("abc"))
