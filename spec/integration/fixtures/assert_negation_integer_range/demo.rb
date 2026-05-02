require "rigor/testing"
include Rigor::Testing

# `RBS::Extended` `rigor:v1:assert n is ~int<5, 10>` (v0.0.5+)
# narrows the target to the complement of the IntegerRange
# within its current domain. The complement decomposes into
# the two open halves `int<min, 4>` and `int<11, max>`; if the
# current domain is a Union with non-Integer parts (e.g.
# `Integer | nil`), those parts survive unchanged.

class OutOfRange
  %a{rigor:v1:assert n is ~int<5, 10>}
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
    # right half (`int<11, …>`) sorts before the left half
    # (`int<min, …>`).
    assert_type("int<11, max> | int<min, 4>", n)
  end
end
