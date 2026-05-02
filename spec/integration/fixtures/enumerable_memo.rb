require "rigor/testing"
include Rigor::Testing

# `IteratorDispatch` v0.0.5 covers the memo-typed Enumerable
# methods alongside `#each_with_index` (v0.0.4):
#
# - `#each_with_object(memo)` yields `(element, memo)` where the
#   memo type follows the second argument's actual type, not the
#   RBS-declared `untyped`.
# - `#inject` / `#reduce` yield `(memo, element)`. With a seed
#   the memo binds to the seed type; with no seed the first
#   element doubles as the initial memo so both block params
#   bind to the receiver's element type.

# each_with_object — Tuple-shaped receiver carries the precise
# element union; the memo arg's type passes through to the second
# block parameter.
[1, 2, 3].each_with_object("") do |elem, memo|
  assert_type("1 | 2 | 3", elem)
  assert_type("\"\"", memo)
end

# inject with a seed: memo type is the seed's, element type is
# the receiver's.
[1, 2, 3].inject(0) do |memo, elem|
  assert_type("0", memo)
  assert_type("1 | 2 | 3", elem)
  memo + elem
end

# inject without a seed: both memo and element bind to the
# receiver's element type (the first iteration uses the first
# element as the memo at runtime).
[1, 2, 3].inject do |memo, elem|
  assert_type("1 | 2 | 3", memo)
  assert_type("1 | 2 | 3", elem)
  memo + elem
end

# reduce is an alias for inject; the binding rule is identical.
[10, 20, 30].reduce("") do |memo, elem|
  assert_type("\"\"", memo)
  assert_type("10 | 20 | 30", elem)
  "#{memo}#{elem}"
end
