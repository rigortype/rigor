require "rigor/testing"
include Rigor::Testing

# `if/else` over a predicate constructs a Symbol-literal union.
# Even though `4.even?` constant-folds to `true`, the engine still
# joins both edges so `result` carries the lattice union of the
# two branch values rather than just the truthy one.
n = 4
result = if n.even?
  :even
else
  :odd
end
assert_type(":even | :odd", result)
