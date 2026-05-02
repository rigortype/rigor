require "rigor/testing"
include Rigor::Testing

# `IteratorDispatch` v0.0.5 placeholder coverage for the
# group_by / partition / each_slice / each_cons family. RBS
# already binds these correctly for plain `Array[T]` receivers;
# the dispatcher exists so Tuple- and HashShape-shaped receivers
# reach the block body with the precise per-position element
# union rather than the projected `Array[union]` widening.
#
# These per-method arms are deliberately narrow — the long-term
# direction is to move Enumerable-aware projections into a
# plugin tier (PHPStan-style) per ADR-2.

# group_by / partition: single-element yield. Tuple-shaped
# receiver carries the precise per-position element union.
[1, 2, 3].group_by do |elem|
  assert_type("1 | 2 | 3", elem)
  elem.even?
end

[10, 20, 30].partition do |elem|
  assert_type("10 | 20 | 30", elem)
  elem > 15
end

# each_slice / each_cons: yield Array[element]. The slice-size
# argument is ignored at the dispatcher tier; tighter
# Tuple-of-`n` carriers are reserved for the plugin tier.
[1, 2, 3, 4].each_slice(2) do |slice|
  assert_type("Array[1 | 2 | 3 | 4]", slice)
end

[1, 2, 3, 4].each_cons(2) do |window|
  assert_type("Array[1 | 2 | 3 | 4]", window)
end
