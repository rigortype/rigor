require "rigor/testing"
include Rigor::Testing

# `Integer#divmod` returns a 2-element `[quotient, remainder]`
# array. The analyzer folds it to a precise `Tuple[Constant, Constant]`
# so the per-slot value is recoverable downstream — including
# through multi-target destructuring.
result = 5.divmod(3)
assert_type("[1, 2]", result)

# Negative dividend uses Ruby's floor-division semantics:
# `-7.divmod(3)` is `[-3, 2]`, not `[-2, -1]`.
neg_result = -7.divmod(3)
assert_type("[-3, 2]", neg_result)

# Float divmod produces a mixed Integer / Float tuple.
mixed = 5.0.divmod(2.5)
assert_type("[2, 0.0]", mixed)

# Multi-target destructuring threads each tuple slot into its own
# local with the precise per-slot type.
q, r = 11.divmod(4)
assert_type("2", q)
assert_type("3", r)
