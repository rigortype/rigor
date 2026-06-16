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
assert_type("bool", (1..5) == (1..5))
assert_type("bool", (1..5).eql?(1..5))

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
# Called WITHOUT a block, `reverse_each` returns an
# `Enumerator` at runtime, so the overload selector picks the
# block-less `() -> Enumerator[Elem, self]` overload.
r = (1..3)
assert_type("Enumerator[Dynamic[top], Range]", r.reverse_each)

# Tier A additions — `entries` and `minmax` folded through
# RANGE_FOLD_METHODS + range_constant_unary.
# `entries` is an alias of `to_a` — lifts to Tuple[Constant…].
assert_type("[1, 2, 3, 4, 5]", (1..5).entries)
# `minmax` returns Tuple[min, max].
assert_type("[1, 10]", (1..10).minmax)
# Empty range `minmax` returns Tuple[nil, nil].
assert_type("[nil, nil]", (1..0).minmax)

# `first(n)` / `take(n)` / `last(n)` — the 1-arg head/tail forms lift to a
# per-position Tuple[Constant…], mirroring the Tuple carrier and the no-arg
# `first`/`last` folds above.
assert_type("[1, 2, 3]", (1..10).first(3))
assert_type("[1, 2, 3]", (1..10).take(3))
assert_type("[8, 9, 10]", (1..10).last(3))
# An exclusive range stops before `end`.
assert_type("[7, 8, 9]", (1...10).last(3))
