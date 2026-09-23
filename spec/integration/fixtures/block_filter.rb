require "rigor/testing"
include Rigor::Testing

# `BlockFolding` collapses the result of block-taking
# Enumerable predicates and filters when the block always
# folds to a Ruby-truthy or Ruby-falsey `Constant`.
#
# The fixtures below exercise the four shapes that landed in
# v0.0.6 phase 1: a non-empty Tuple receiver under `any?`,
# an Array receiver under `select { false }`, an Array under
# `all? { true }`, and a non-empty `Difference[Array, Tuple[]]`
# receiver under `none?`.

# `[10, 20].any? { |x| x > 0 }` — the block body folds to
# `Constant[true]` for both elements (10>0 and 20>0 are
# constant-foldable), so the call is unconditionally `true`.
non_empty_any = [10, 20].any? { |x| x > 0 }
assert_type("true", non_empty_any)

# `[1, 2, 3].select { false }` — the block always returns
# `Constant[false]`, so the result is the empty tuple.
empty_select = [1, 2, 3].select { false }
assert_type("[]", empty_select)

# `[1, 2, 3].all? { true }` — block always truthy, so the
# call folds to `Constant[true]` regardless of receiver
# shape (vacuous-truth side handled too: see the spec).
all_truthy = [1, 2, 3].all? { true }
assert_type("true", all_truthy)

# `Hash#select` / `#reject` return a Hash, so dropping every entry
# folds to the empty HashShape rather than the empty tuple — the
# latter made `hash_rejected[:x] = 1` report an argument-type
# mismatch on correct code.
hash_rejected = { a: :q }.reject { |_k, _v| true }
assert_type("{}", hash_rejected)
hash_rejected[:x] = 1

hash_selected = { a: :q }.select { false }
assert_type("{}", hash_selected)
hash_selected[:x] = 1

# `Hash#take_while` is Enumerable's and returns an Array of pairs.
hash_taken = { a: :q }.take_while { false }
assert_type("[]", hash_taken)
