require "rigor/testing"
include Rigor::Testing

# Methods unlocked by extracting the Range catalog from
# `Init_Range` in `references/ruby/range.c`. The hand-rolled
# unary/binary allow lists do not cover Range — the offline
# catalog is the only path that accepts these calls today.
#
# Constant<Range> receivers come from `(1..10)` literals where
# both endpoints are static IntegerNodes (see
# `ExpressionTyper#type_of_range`). Beginless / endless ranges
# stay at `Nominal[Range]` and therefore route through the
# size-returning nominal tier instead.

# Read-only accessors on a Constant<Range> fold to Constant<Integer>.
assert_type("1", (1..10).begin)
assert_type("10", (1..10).end)
assert_type("10", (1..10).size)
assert_type("false", (1..10).exclude_end?)
assert_type("true", (1...10).exclude_end?)

# Membership predicates fold to Constant<bool>.
assert_type("true", (1..5).include?(3))
assert_type("false", (1..5).include?(7))
assert_type("true", (1..5).cover?(3))
assert_type("false", (1..5).cover?(0))
assert_type("true", (1..5).member?(5))
assert_type("false", (1..5).member?(6))

# Equality / structural comparison. `Range#==` and `Range#eql?`
# are catalog-classified `dispatch` (the C body delegates to
# `rb_funcall(begin)` / `rb_funcall(end)` for user-redefinable
# `==`), so the fold tier conservatively bails. The RBS tier
# answers with `bool` (`false | true`) for both branches.
assert_type("false | true", (1..5) == (1..5))
assert_type("false | true", (1..5).eql?(1..5))

# Range#size on a fully unbounded `Constant<Range>` literal
# folds to `Constant[Float::INFINITY]` (Range#size returns
# Float::INFINITY at runtime for endless ranges). The size-
# returning nominal tier — which would tighten an opaque
# `Nominal[Range]` to `non-negative-int` — is documented for
# completeness; reaching it from this fixture would require a
# non-literal Range source (a method return type), which the
# Range catalog import does not yet stress.
assert_type("Infinity", (1..).size)

# Mutators / pseudo-mutators are blocklisted so the dispatcher
# never folds them into a Constant. `reverse_each` actually
# yields to a block (the C-body classifier mis-flags it as
# `:leaf`); the blocklist keeps the analyzer from inventing a
# `Constant<Range>` answer for an Enumerator-returning call.
# The conservative fall-through answer comes from the RBS-tier
# projection of the receiver's nominal — `Range` here.
r = (1..3)
assert_type("Range", r.reverse_each)
