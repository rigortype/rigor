require "rigor/testing"
include Rigor::Testing

# `RBS::Extended` `rigor:v1:assert <name> is ~<refinement>` (v0.0.5)
# narrows the target to the complement of the refinement within
# its current domain. For `Difference[base, Constant[v]]` shapes
# the narrowing returns the matching `Constant[v]` (plus any
# parts of the original domain that were already disjoint from
# `base`).
#
#   class Validator
#     %a{rigor:v1:assert value is ~non-empty-string}
#     def assert_empty!: (::String value) -> void
#   end
#
# After the call, `value` is narrowed away from
# `non-empty-string` — the only remaining inhabitant of `String`
# is `Constant[""]`.
class Validator
  def assert_empty!(value)
    raise ArgumentError, "non-empty" unless value.empty?
  end
end

# A method whose `name` parameter is RBS-declared `String` (the
# binder lifts it to `Nominal[String]` inside the body). After
# `assert_empty!(name)`, the only String inhabitant left after
# the negation is the empty string.
class StringSink
  def visit(name)
    v = Validator.new
    v.assert_empty!(name)
    assert_type("\"\"", name)
  end
end
