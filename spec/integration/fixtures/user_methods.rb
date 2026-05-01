require "rigor/testing"
include Rigor::Testing

# v0.0.2 #5 — inter-procedural inference for user-defined
# methods. The engine re-types the body of `is_odd` /
# `is_even` at the call site, binding the parameter `n` to
# the call's argument type. `n.odd?` resolves to `bool`
# (Integer#odd?'s declared return), so the caller observes
# `false | true` instead of the v0.0.1 `Dynamic[top]`.
#
# The matching `user_methods_with_sig/` fixture demonstrates
# the same outcome via an RBS sig — both paths now produce
# the same precise return type.
class Parity
  def is_odd(n)
    n.odd?
  end

  def is_even(n)
    n.even?
  end
end

p = Parity.new
assert_type("Parity", p)

a = p.is_odd(3)
b = p.is_even(4)

assert_type("false | true", a)
assert_type("false | true", b)
