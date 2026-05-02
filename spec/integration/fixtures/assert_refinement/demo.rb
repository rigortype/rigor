require "rigor/testing"
include Rigor::Testing

# `RBS::Extended` `rigor:v1:assert` accepts refinement names on
# the right-hand side (v0.0.4): the post-call narrowing tier
# substitutes the refinement carrier for the target's bound
# type, so subsequent reads see the refined carrier rather than
# the wider original.
#
#   class Validator
#     %a{rigor:v1:assert value is non-empty-string}
#     def assert_present!: (::String value) -> void
#   end
class Validator
  def assert_present!(value)
    raise ArgumentError, "empty" if value.empty?
  end
end

v = Validator.new
name = "Alice"

# Before the assert call the local is a Constant<String>; the
# directive substitutes the refinement carrier so subsequent
# reads see `non-empty-string`.
v.assert_present!(name)
assert_type("non-empty-string", name)
assert_type("positive-int", name.size)
