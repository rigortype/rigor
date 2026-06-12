require "rigor/testing"
include Rigor::Testing

# Item 3 / ranked-slice 3 — the truthy edge of a safe-navigation call
# (`v&.pred`) proves the receiver non-nil, because `&.` short-circuits to
# `nil` on a nil receiver. So in `v&.start_with?('[') && v.end_with?(']')`
# the `&&` right operand sees `v` non-nil and the bare `v.end_with?` read
# is clean — previously it fired a spurious `possible nil receiver`.
def in_and(flag)
  v = flag ? "[x]" : nil
  return unless v&.start_with?("[") && v.end_with?("]")

  assert_type('"[x]"', v)
  v.length
end

# A bare safe-nav truthy edge (no `&&`) narrows the same way.
def bare(flag)
  v = flag ? "[x]" : nil
  return unless v&.length

  assert_type('"[x]"', v)
  v.upcase
end
