require "rigor/testing"
include Rigor::Testing

# An if/else builds a `String | nil` union for `x`. Inside an
# `is_a?(String)` truthy branch the analyzer narrows `x` down to
# the String fragment of the union — the literal `"hello"` here.
# The else branch sees the complement, the nil fragment.
x = if rand < 0.5
  "hello"
else
  nil
end
if x.is_a?(String)
  assert_type('"hello"', x)
else
  assert_type("nil", x)
end
