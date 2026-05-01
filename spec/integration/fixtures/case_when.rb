require "rigor/testing"
include Rigor::Testing

# `case/when` over an integer subject constructs a precise
# Symbol-literal union from the branch results — one slot per
# `when` arm (plus `else`).
n = 0
label = case n
        when 0 then :zero
        when 1..9 then :small
        else :large
        end
assert_type(":large | :small | :zero", label)

# Inside each `when` arm the subject is narrowed to the matching
# integer range. Integer literals collapse to a `Constant`;
# inclusive (`..`) and exclusive (`...`) ranges produce
# `IntegerRange` carriers.
m = rand(100)
case m
when 1..10
  assert_type("int<1, 10>", m)
when 11..20
  assert_type("int<11, 20>", m)
end

# Exclusive end shifts the upper bound by one.
k = rand(100)
case k
when 0...10
  assert_type("int<0, 9>", k)
end

# Endless / beginless ranges produce half-line bounds. Wrap in
# parens so Ruby's grammar parses them as standalone ranges
# rather than swallowing the next expression.
j = rand(100)
case j
when (100..)
  assert_type("int<100, max>", j)
when (..-1)
  assert_type("negative-int", j)
end

# A single-integer `when` collapses the subject to that
# `Constant`.
i = rand(100)
case i
when 0
  assert_type("0", i)
end
