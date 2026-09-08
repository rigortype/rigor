require "rigor/testing"
include Rigor::Testing

# `RBS::Extended` `rigor:v1:assert n is ~Integer[5..10]` (v0.0.5+)
# narrows the target to the complement of the IntegerRange
# within its current domain. The complement decomposes into
# the two open halves `Integer[..4]` and `Integer[11..]`; if the
# current domain is a Union with non-Integer parts (e.g.
# `Integer | nil`), those parts survive unchanged.

class OutOfRange
  %a{rigor:v1:assert n is ~Integer[5..10]}
  def assert_outside!(n)
    raise ArgumentError, "in range" if (5..10).include?(n)
  end
end

class IntSink
  def visit(n)
    o = OutOfRange.new
    o.assert_outside!(n)
    # `n` was `Nominal[Integer]` from the RBS-declared parameter.
    # The negation narrows it to the union of the two open halves.
    # Union members render in describe(:short) lex order, so the
    # left half (`Integer[..…]`) sorts before the right half
    # (`Integer[11..…]`): `[.` precedes `[1`.
    assert_type("Integer[..4] | Integer[11..]", n)
  end
end
