require "rigor/testing"
include Rigor::Testing

# `IteratorDispatch` v0.0.4 generalises beyond Integer iteration:
# `#each_with_index` now yields the receiver's element type
# alongside a tightened `non-negative-int` index, regardless of
# whether the receiver is an Array literal (Tuple), a static
# Hash literal (HashShape), or a generic `Nominal` carrier.

[1, 2, 3].each_with_index do |elem, idx|
  # Tuple-shaped receiver preserves per-position element types
  # (union of all elements). The index tightens to
  # non-negative-int rather than the RBS-declared Integer.
  assert_type("1 | 2 | 3", elem)
  assert_type("non-negative-int", idx)
end

# Hash literal: HashShape projects each pair as Tuple[Symbol, V].
{ a: 1, b: 2 }.each_with_index do |pair, idx|
  assert_type("[:a | :b, 1 | 2]", pair)
  assert_type("non-negative-int", idx)
end

# Constant Range receiver: precise integer-range element.
(5..7).each_with_index do |i, idx|
  assert_type("int<5, 7>", i)
  assert_type("non-negative-int", idx)
end
