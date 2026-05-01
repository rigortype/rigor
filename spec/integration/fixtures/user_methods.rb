require "rigor/testing"
include Rigor::Testing

# v0.0.3 C — aggressive constant folding through user
# methods. Layers on top of v0.0.2 #5's inter-procedural
# inference: the engine re-types the body of `is_odd` /
# `is_even` at the call site with the call's argument
# bound to the parameter, AND the unary constant-folding
# catalogue evaluates `Constant[3].odd?` directly to
# `Constant[true]`. The caller therefore observes the
# exact boolean result, not the RBS-widened
# `false | true` it saw in v0.0.2.
#
# The matching `user_methods_with_sig/` fixture pins the
# RBS-widened path: when the user supplies a sig
# (`def is_odd: (Integer) -> bool`) the engine uses the
# declared return type and the constant-fold cannot
# narrow it. Both behaviours are intentional — the sig
# is the authoritative contract when present.
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

# 3.odd? folds to true, 4.even? folds to true.
assert_type("true", a)
assert_type("true", b)
