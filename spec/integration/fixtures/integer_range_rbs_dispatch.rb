require "rigor/testing"
include Rigor::Testing

# Issue #842 — `RbsDispatch#receiver_descriptor` had no arm for `Type::IntegerRange`, so any method
# the fold tiers (ConstantFolding, ShapeDispatch#dispatch_integer_range) do not own fell soft to
# `Dynamic[top]` instead of reaching RBS. `Integer#digits`/`#fdiv`/`#to_f` are exactly that: RBS-only
# methods over a bounded-integer receiver.
n = ARGV.size
assert_type("non-negative-int", n)

# The fold tiers keep winning for the methods they own — unaffected by this change.
assert_type("positive-int", n + 1)
assert_type("positive-int", n.succ)
assert_type("Integer[1..9]", n.clamp(1, 9))
assert_type("decimal-int-string", n.to_s)

# Newly reached through RBS dispatch instead of falling to Dynamic[top].
assert_type("Array[Integer]", n.digits)
assert_type("Float", n.fdiv(2))
assert_type("Float", n.to_f)
