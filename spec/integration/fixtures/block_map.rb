require "rigor/testing"
include Rigor::Testing

# v0.0.6 phase 2 — per-element block re-evaluation over a
# Tuple-shaped receiver. The block body is typed once per
# position with the corresponding constant bound to the
# parameter, and the assembled answer is the per-position
# Tuple of stringified constants — strictly tighter than
# the previous `Array["1" | "2" | "3"]` projection.
strings = [1, 2, 3].map { |n| n.to_s }
assert_type('["1", "2", "3"]', strings)
