require "rigor/testing"
include Rigor::Testing

# Methods unlocked by extracting the String/Symbol catalog from
# `Init_String` in `references/ruby/string.c`. The hand-rolled
# `STRING_UNARY` / `STRING_BINARY` sets do not cover these — the
# offline catalog adds them.
assert_type('"h"', "hello"[0])
assert_type("true", "abc".include?("b"))
assert_type("true", "abc".start_with?("a"))
assert_type("false", "abc".end_with?("a"))
assert_type("0", "abc".index("a"))
assert_type("1", "abc".count("a"))
assert_type("\"\\\"hi\\\"\"", "hi".inspect)

# Symbol catalog: String/Symbol live in the same `string.yml` so
# Symbol#length / #empty? / #casecmp? all fold once the receiver
# is a `Symbol` literal.
assert_type("3", :foo.length)
assert_type("false", :foo.empty?)
assert_type("true", :a.casecmp?(:A))

# Mutating selectors are blocklisted — the catalog mis-classifies
# `String#replace` as `:leaf` because the C body uses
# `str_modifiable` (a helper the regex classifier does not yet
# follow). The wired-in blocklist drops these so the analyzer
# never folds a mutator on a frozen Constant.
s = "hi"
# `s.replace("ho")` would raise FrozenError at runtime against a
# frozen String literal carrier; the rule keeps the fold inert
# and the RBS tier answers with `Nominal[String]` instead.
assert_type("String", s.replace("ho"))
