require "rigor/testing"
include Rigor::Testing

# ADR-57 slice 3 work-item 2 — FP-safe optional-slot destructure softening.
#
# Destructuring a tuple slot that flow typed as optional (`X | nil`) softens
# that slot to its non-`nil` part. A nil-able tuple slot is almost always
# guarded by a CORRELATED invariant flow cannot prove (the canonical case is
# haml's `parse_tag`, whose 9-tuple `last_line` slot is nil only when an
# earlier slot is, and the call-site guard short-circuits), so manufacturing a
# `T?` per destructured slot frightens working code — FP discipline outranks
# the worst-case per-slot reading.

# A heterogeneous tuple whose second slot is optional: the destructured `b`
# drops the `nil` and keeps the non-nil constituent, so a later `b - 1` would
# not false-fire as a possible-nil receiver.
def optional_pair = [1, (rand > 0.5 ? 2 : nil)]
_, b = optional_pair
assert_type("2", b)

# A pure (non-optional) tuple slot keeps its precise type unchanged.
def plain_pair = [1, "x"]
c, d = plain_pair
assert_type("1", c)
assert_type("\"x\"", d)

# A bare `nil` slot (no non-nil constituent) stays `nil` — nothing to soften.
def nil_pair = [1, nil]
_, f = nil_pair
assert_type("nil", f)
