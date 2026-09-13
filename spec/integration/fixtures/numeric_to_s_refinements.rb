require "rigor/testing"
include Rigor::Testing

# #993 — `Integer#to_s` / `Float#to_s` (and `#inspect`, the same value grammar) on a non-literal
# receiver used to land at bare `String`. `finite-float`, the `Float[...]` range refinement, and
# the `f.finite?` truthy-edge narrowing this issue leans on are covered by
# `float_comparison_narrowing.rb`; this fixture pins the bare-receiver floor each class projects to
# with no further proof available.

i = Integer(ARGV[0])
f = Float(ARGV[1])

# `decimal-int-string`'s predicate admits a leading sign, so a bare (sign-unknown) Integer still
# reaches it for base 10 — the default, and the only base that does.
assert_type("decimal-int-string", i.to_s)
assert_type("decimal-int-string", i.to_s(10))
assert_type("decimal-int-string", i.inspect)

# A non-decimal base's digits carry no refinement Rigor names: `255.to_s(16)` is `"ff"`, not the
# `0xff` literal `hex-int-string` expects. `to_s(base)` is still total (never `""`).
assert_type("non-empty-string", i.to_s(16))
assert_type("non-empty-string", i.to_s(8))

# A base that is not statically known gets the same non-empty-string floor as a known non-decimal
# base — the analyser cannot tell it apart from one.
base = Integer(ARGV[2])
assert_type("non-empty-string", i.to_s(base))

# A bare Float carries no finiteness proof — it admits Infinity / -Infinity / NaN, none of which
# are Ruby numeric literals — so the floor is non-empty-string, never numeric-string.
assert_type("non-empty-string", f.to_s)
assert_type("non-empty-string", f.inspect)

# `Float::NAN` is deliberately excluded from the constant-folding whitelist (non-reflexive `==`,
# see `predefined_constant_refinements.rb`), so it stays a bare `Float` here and reaches the same
# non-empty-string floor as any other Float — pinning that a later widening cannot quietly reclaim
# it as numeric-string.
assert_type("non-empty-string", Float::NAN.to_s)
