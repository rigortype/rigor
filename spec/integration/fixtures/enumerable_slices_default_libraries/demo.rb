require "rigor/testing"
include Rigor::Testing

# Issue #1109 — the `rbs` gem is a default library, and its own
# `sig/shims/enumerable.rbs` used to prepend a `(2) -> Enumerator[[Elem,
# Elem], void]` overload to `Enumerable#each_slice`. CRuby contradicts
# it: the last slice can be shorter than `n` (`[1, 2, 3].each_slice(2)`
# yields `[1, 2]`, then `[3]`). A project fixture, because only
# `Environment.for_project` loads the default libraries.
class SliceDemo
  def ints = [1, 2, 3]
end

ints = SliceDemo.new.ints

# The blockless forms agree with the block forms' `Array[Integer]`
# slice, so a `nil` guard on the second slot keeps both arms.
assert_type("Enumerator[Array[Integer], Array[Integer]]", ints.each_slice(2))
ints.each_slice(2).each_with_index do |(_first, second), _index|
  assert_type("1 | 2", second.nil? ? 1 : 2)
end
ints.each_slice(2) { |_first, second| assert_type("1 | 2", second.nil? ? 1 : 2) }

# The block form returns the receiver, not the shim's `void`.
assert_type("Array[Integer]", ints.each_slice(2) { |slice| slice })

# `each_cons` windows are always exactly `n` long, but the enumerator
# is empty when the receiver is shorter than `n`, so `Array[Integer]`
# is the sound element there too. The shim never touched it.
assert_type("Enumerator[Array[Integer], Array[Integer]]", ints.each_cons(2))

# A literal Tuple receiver gets no fixed n-tuple either: it keeps the
# per-position element union, as its block form does.
assert_type("Enumerator[Array[1 | 2 | 3], Array[Integer]]", [1, 2, 3].each_slice(2))
assert_type("Enumerator[Array[1 | 2 | 3 | 4], Array[Integer]]", [1, 2, 3, 4].each_slice(2))
