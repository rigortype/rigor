require "rigor/testing"
include Rigor::Testing

# Without an accompanying RBS sig, the engine has no
# inter-procedural inference yet: the BODY of `is_odd` /
# `is_even` is typed correctly inside the def, but the
# RETURN TYPE is not propagated to the caller. A direct
# call therefore types as `Dynamic[top]`.
#
# This fixture pins that current limitation. The matching
# `user_methods_with_sig/` fixture demonstrates how an RBS
# sig closes the gap.
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

assert_type("Dynamic[top]", a)
assert_type("Dynamic[top]", b)
