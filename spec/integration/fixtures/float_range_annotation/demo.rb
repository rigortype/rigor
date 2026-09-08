require "rigor/testing"
include Rigor::Testing

# ADR-109 WD4 — a `Float[R]` payload is the set of Floats the Ruby range literal covers. The carrier
# arrives only through annotations in this slice (no comparison narrowing yet), so the fixture pins
# the three things a bounded Float must do: display as written, dispatch as a Float, and take part
# in argument acceptance on both sides.

class Ratio
  def unit = 0.5
  def safe = 1.0
  def magnitude = 2.0
  def take_unit(x) = nil
  def take_float(x) = nil
  def take_integer(x) = nil
end

r = Ratio.new
u = r.unit
assert_type("Float[0.0..1.0]", u)
assert_type("non-nan-float", r.safe)
assert_type("Float[0.0...Float::INFINITY]", r.magnitude)

# No Float folds exist yet, so a method on the bounded receiver resolves through `Float`'s RBS: the
# carrier is a Float for every method the fold tiers do not own.
assert_type("Integer", u.round)
assert_type("Float", u + 1.0)
assert_type("bool", u.nan?)

# `Float[0.0..1.0]` is-a `Float`, and is contained in itself; a `Float` is not contained in it (it may
# be NaN or lie outside), an Integer is not a Float, and `1.5` lies outside the range.
r.take_float(u)
r.take_unit(u)
r.take_integer(u) # rigor:disable argument-type-mismatch
r.take_unit(1.5) # rigor:disable argument-type-mismatch
r.take_unit(r.safe) # rigor:disable argument-type-mismatch
