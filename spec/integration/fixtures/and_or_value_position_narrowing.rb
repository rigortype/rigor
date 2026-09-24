require "rigor/testing"
include Rigor::Testing

# Issue #1016 — a bare `&&` / `||` narrows its right operand under the left operand's edge the same way in statement
# position and in value position. The `*_stmt` locals are statement-position bindings; every `assert_type` argument
# is the same expression in value position (a call argument), which is the position that used to lose the narrowing.

x = Float(ARGV[0])
s = (ARGV.first if rand < 0.5)
a = ARGV
v = if rand < 0.5 then 1 else "str" end
sym = if rand < 0.5 then :a else :b end
ones = [1, 1]
idx = ARGV.size

finite_stmt = x.finite? && x
assert_type("false | finite-float", x.finite? && x)
assert_type("[false | finite-float]", [x.finite? && x])

nan_stmt = x.nan? || x
assert_type("non-nan-float | true", x.nan? || x)

# A comparison's falsey edge keeps the entry type: `!(x > 0.0)` is also true of NaN.
cmp_truthy_stmt = x > 0.0 && x
cmp_falsey_stmt = x > 0.0 || x
assert_type("Float[0.0..] | false", x > 0.0 && x)
assert_type("Float | true", x > 0.0 || x)

nil_stmt = s.nil? || s
assert_type("String | true", s.nil? || s)

class_stmt = v.is_a?(Integer) && v
assert_type("1 | false", v.is_a?(Integer) && v)

empty_stmt = a.empty? || a
assert_type("non-empty-array[String] | true", a.empty? || a)

literal_stmt = sym == :a && sym
assert_type(":a | false", sym == :a && sym)

nested_stmt = !(s && x.finite?) || [s, x]
assert_type("[String, finite-float] | true", !(s && x.finite?) || [s, x])

# The constant short-circuit, shared by both positions, and its issue #313 decline on an optimistic lookup. The
# lookup is `Array#[]` at a computed index, read past its `%a{implicitly-returns-nil}` as a lone `1`; a literal hash
# no longer serves, since its shape reads a computed key with the nil arm and the fallback survives without the decline.
short_circuit_stmt = 1 || s
assert_type("1", 1 || s)
fallback_stmt = ones[idx] || 5
assert_type("1 | 5", ones[idx] || 5)
