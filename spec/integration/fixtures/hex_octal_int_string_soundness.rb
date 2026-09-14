require "rigor/testing"
include Rigor::Testing

# #1004 — two producers claimed `hex-int-string` / `octal-int-string` for strings the refinement's
# own predicate rejects (`refined.rb`'s `HEX_INT_STRING_PATTERN` / `OCTAL_INT_STRING_PATTERN`
# REQUIRE the `0x` / `0o` prefix). Neither producer below ever emits that prefix, so both drop to
# the `non-empty-string` floor #993 / #1001 already established for the sibling `Nominal[Integer]`
# path: `n.to_s(base)` and a matched capture are each total / non-empty, just not prefixed.

# Producer 1 — `IntegerRange#to_s(base)` on a bounded, provably non-negative receiver (`rand(100)`
# is `container_size.rb`'s own oracle for this carrier). Base 10 is unaffected: it is Ruby's
# decimal-literal grammar, so it still reaches `decimal-int-string`.
n = rand(100)
assert_type("decimal-int-string", n.to_s)
assert_type("decimal-int-string", n.to_s(10))
assert_type("non-empty-string", n.to_s(16))
assert_type("non-empty-string", n.to_s(8))

# Producer 2 — the regex-source recogniser narrowing a named capture. `\h+` / `[0-9a-fA-F]+` /
# `[0-7]+` match a prefix-free digit run ("ff", "17"), so they narrow to `non-empty-string`, never
# the prefixed-literal refinements.
str = "input"
if /(?<hash>\h+)/ =~ str
  assert_type("non-empty-string", hash)
end

if /(?<oct>[0-7]+)/ =~ str
  assert_type("non-empty-string", oct)
end
