require "rigor/testing"
include Rigor::Testing

# v0.0.6 phase 2 — per-element block re-evaluation for `:map`
# (and its alias `:collect`) over Tuple receivers. The block
# body is type-checked once per Tuple position with the
# corresponding element bound to the block parameter, and the
# assembled answer is the per-position Tuple — strictly
# tighter than the RBS-projected `Array[union]`.

# Different per-position element types: each call to `to_s`
# produces a `Constant` whose value reflects the element's
# original constant.
mixed = [1, "two", :three].map { |x| x.to_s }
assert_type('["1", "two", "three"]', mixed)

# `:collect` is a Ruby alias for `:map`; it must also fold.
collected = [10, 20].collect { |n| n + 5 }
assert_type("[15, 25]", collected)

# Per-position arithmetic — each element binds to a different
# `Constant<Integer>` so each block evaluation folds to a
# distinct constant.
shifts = [1, 2, 3].map { |n| n * 10 }
assert_type("[10, 20, 30]", shifts)

# Numbered parameters work the same way.
numbered = [1, 2, 3].map { _1 + 1 }
assert_type("[2, 3, 4]", numbered)

# `:filter_map` participates when every per-position result
# is a `Constant`. nil / false positions drop, the rest
# survive in declaration order.
filter_mapped_keep = [1, 2, 3].filter_map { |n| n.to_s }
assert_type('["1", "2", "3"]', filter_mapped_keep)

# All positions drop → empty Tuple.
filter_mapped_drop = [1, 2, 3].filter_map { |_n| nil }
assert_type("[]", filter_mapped_drop)

# v0.0.6 — branch elision for expression-position
# conditionals on Constant predicates composes with the
# Phase 2 per-element fold and the `:filter_map` extension:
# at each Tuple position, `n.even?` folds to a precise
# `Constant[bool]`, the ternary's unreachable branch is
# elided, and the surviving Constant feeds the per-position
# drop step.
filter_mapped_evens = [1, 2, 3].filter_map { |n| n.even? ? n.to_s : nil }
assert_type('["2"]', filter_mapped_evens)

# `:flat_map` participates when every per-position result is
# itself a Tuple. The Tuples concatenate in declaration order
# into the final Tuple.
flat_pairs = [1, 2, 3].flat_map { |n| [n, n * 10] }
assert_type("[1, 10, 2, 20, 3, 30]", flat_pairs)

# Heterogeneous Tuple sizes (with branch elision deciding the
# Tuple size per position).
flat_varied = [1, 2].flat_map { |n| n.even? ? [n, n] : [n] }
assert_type("[1, 2, 2]", flat_varied)

# v0.0.6 — mixed-shape flat_map. A `Constant` per-position
# result (non-Array scalar) contributes one element; the
# overall fold concatenates Tuples and singletons in
# declaration order.
flat_scalar = [1, 2, 3].flat_map { |n| n.to_s }
assert_type('["1", "2", "3"]', flat_scalar)

# v0.0.6 — `[]` literal resolves to `Tuple[]`, which lets
# `:flat_map` concatenate cleanly across all-empty per-position
# results.
flat_all_empty = [1, 2, 3].flat_map { |_n| [] }
assert_type("[]", flat_all_empty)

# `:find` / `:detect` truthy-block side: every per-position
# block result folds to a Constant, so the dispatcher walks
# the Tuple and returns the receiver element at the first
# truthy index.
first_even = [1, 2, 3, 4].find { |n| n.even? }
assert_type("2", first_even)

# All positions fold to Constant[false]: result is
# Constant[nil].
no_match = [1, 3, 5].find { |n| n.even? }
assert_type("nil", no_match)

# `:find_index` returns the index of the first truthy match.
idx_first_even = [1, 2, 3, 4].find_index { |n| n.even? }
assert_type("1", idx_first_even)

# `:index` (block form) is an alias of find_index.
idx_alias = [1, 2, 3, 4].index { |n| n.even? }
assert_type("1", idx_alias)

# v0.0.6 — finite-bound `Constant<Range>` receivers also
# participate in the per-element block fold, up to the
# `PER_ELEMENT_RANGE_LIMIT` cardinality cap.
range_mapped = (1..3).map { |n| n.to_s }
assert_type('["1", "2", "3"]', range_mapped)

range_first_even = (1..5).find { |n| n.even? }
assert_type("2", range_first_even)

range_first_idx = (1..5).find_index { |n| n.even? }
assert_type("1", range_first_idx)
