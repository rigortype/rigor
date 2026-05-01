require "rigor/testing"
include Rigor::Testing

# Literals constant-fold.
n = 4
assert_type("4", n)

# An if-else over a constant-folded predicate (`4.even?` -> `true`)
# resolves to the live branch only. A wider receiver would keep
# both edges and the result would join into a Symbol-literal union.
parity = if n.even?
  :even
else
  :odd
end
assert_type(":even", parity)

# case/when over an integer subject constructs a three-way union.
label = case n
        when 0 then :zero
        when 1..9 then :small
        else :large
        end
assert_type(":large | :small | :zero", label)

# Compound writes constant-fold and rebind.
counter = 10
counter += 5
counter -= 3
assert_type("12", counter)

# `||=` on a nil-bound local replaces it with the rvalue.
cached = nil
cached ||= "hit"
assert_type('"hit"', cached)

# Tuple element access surfaces precise constants.
xs = [10, 20, 30]
assert_type("10", xs.first)
assert_type("20", xs[1])
assert_type("30", xs.last)

# HashShape entry access surfaces precise constants.
h = { name: "Alice", age: 30 }
assert_type('"Alice"', h[:name])
assert_type("30", h.fetch(:age))
