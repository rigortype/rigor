require "rigor/testing"
include Rigor::Testing

# Per-element block fold for `select` / `filter` / `reject` over
# a Tuple-shaped receiver. The predicate is evaluated once per
# position with the element bound to the block parameter; the
# surviving positions assemble into a `Tuple`, strictly tighter
# than the RBS-projected `Array[Elem]`.

# `select` / `filter` with a full block — keeps the positions
# whose predicate folds to a Ruby-truthy `Constant`.
evens = [1, 2, 3, 4].select { |n| n.even? }
assert_type("[2, 4]", evens)

filtered = [1, 2, 3, 4].filter { |n| n > 2 }
assert_type("[3, 4]", filtered)

# `reject` with a full block — keeps the Ruby-falsey positions.
non_nil = [1, 2, nil].reject { |x| x.nil? }
assert_type("[1, 2]", non_nil)

# `&:predicate` symbol-proc shorthand resolves identically: the
# symbol is dispatched as a zero-arg method on each element.
non_nil_sym = [1, 2, nil].reject(&:nil?)
assert_type("[1, 2]", non_nil_sym)

only_nil = [1, 2, nil].select(&:nil?)
assert_type("[nil]", only_nil)

odds = [1, 2, 3, 4, 5].select(&:odd?)
assert_type("[1, 3, 5]", odds)

# `compact` removes the `nil` positions through `ShapeDispatch`
# — the same Tuple-shaped result the predicate folds reach.
compacted = [1, 2, nil].compact
assert_type("[1, 2]", compacted)

# Every position dropped folds to the empty-tuple carrier.
nothing = [1, 2, 3].reject { |n| n.positive? }
assert_type("[]", nothing)
