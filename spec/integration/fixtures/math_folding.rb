require "rigor/testing"
include Rigor::Testing

# Math module-function folding (Tier D). Math is a core module, so
# no `require` is needed and a flat fixture suffices.

# Single-argument transcendental functions fold to Constant[Float].
assert_type("2.0", Math.sqrt(4.0))
assert_type("3.0", Math.cbrt(27.0))
assert_type("1.0", Math.exp(0))
assert_type("3.0", Math.log2(8))
assert_type("3.0", Math.log10(1000))
assert_type("0.0", Math.sin(0))
assert_type("1.0", Math.cos(0))

# Two-argument functions fold to Constant[Float].
assert_type("5.0", Math.hypot(3.0, 4.0))
assert_type("4.0", Math.ldexp(0.5, 3))

# Math.log — both the one- and two-argument forms fold.
assert_type("0.0", Math.log(1))
assert_type("3.0", Math.log(8, 2))

# frexp returns [mantissa, exponent] — lifted to a Tuple.
assert_type("[0.5, 4]", Math.frexp(8.0))

# A domain-error input declines the fold; the RBS tier answers
# with the widened Float envelope.
assert_type("Float", Math.sqrt(-1))
