require "rigor/testing"
include Rigor::Testing

# ADR-109 — the folds that produce a bounded Float without an annotation, and the ones a bounded
# Float takes part in. Every result below is the closed envelope of what Ruby returns; a call that
# can raise for some value in the range (an infinite bound reaching `floor`, an exclusive `clamp`
# bracket) declines to the RBS type instead.

u = rand(0.0...1.0)
assert_type("Float[0.0...1.0]", u)
assert_type("Integer[1..6]", rand(1..6))
assert_type("Float[1.0..2.0]", Random.rand(1.0..2.0))
# The bare, Integer-max and Float-max forms stay the RBS type: the corpus reads them as its
# unknown-value oracle.
assert_type("Float", rand)
assert_type("Integer", rand(6))

assert_type("false", u.nan?)
assert_type("true", u.finite?)
assert_type("Float[0.0...1.0]", u.abs)
assert_type("Float[-0.9999999999999999..0.0]", -u)
assert_type("0", u.floor)
assert_type("Integer[0..1]", u.round)
assert_type("Float[0.0...1.0]", u.clamp(0.0, 1.0)) # the receiver's exclusive end is the tighter one
assert_type("Float[0.25..0.75]", u.clamp(0.25..0.75))
assert_type("true", u.between?(0.0, 1.0))

n = ARGV.size
assert_type("Float[0.0..]", Math.sqrt(n))
assert_type("Float[1.0..]", Math.exp(n))
assert_type("Integer[1..9]", n.clamp(1..9))
assert_type("positive-int", n.clamp(1..))

x = Float(ARGV[0])
if x >= 0.0
  assert_type("Float[0.0..]", Math.sqrt(x))
  assert_type("Float[0.0..]", x.abs)
end
# A plain Float takes no fold: it may be NaN, and Math.sqrt raises on a negative value.
assert_type("Float", Math.sqrt(x))
assert_type("Float", x.abs)
