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
