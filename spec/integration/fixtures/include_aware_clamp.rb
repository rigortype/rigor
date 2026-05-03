require "rigor/testing"
include Rigor::Testing

# v0.0.5+ include-aware module-catalog fallthrough.
# `Integer#clamp(0..10)` is provided by the included Comparable
# module rather than registered directly on Integer in
# `Init_Numeric`, so numeric.yml has no entry. The catalog
# dispatcher used to bail at this point; the new fallthrough
# consults `COMPARABLE_CATALOG`, which classifies `clamp` as
# `:leaf`, and the fold materialises by invoking the actual
# Ruby method.

# Clamp inside the range — receiver itself.
assert_type("5", 5.clamp(0..10))

# Clamp above the range — upper bound.
assert_type("10", 100.clamp(0..10))

# Clamp below the range — lower bound.
assert_type("0", (-5).clamp(0..10))
