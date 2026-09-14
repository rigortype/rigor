require "rigor/testing"
include Rigor::Testing

# Issue #1003 — a predicate guard narrows its subject the same way in the `if` spelling and the ternary
# spelling, in statement position and in value position. Each guard below is written both ways side by
# side: the `*_if` / `*_tern` locals are statement-position bindings, and every `assert_type` argument is a
# value-position conditional (a call argument), which is the position that used to lose the narrowing.

x = Float(ARGV[0])
s = (ARGV.first if rand < 0.5)
a = ARGV
v = if rand < 0.5 then 1 else "str" end

# ADR-109 WD5 — `finite?` narrows only its truthy edge.
finite_if = if x.finite? then x else 0.0 end
finite_tern = x.finite? ? x : 0.0
assert_type("0.0 | finite-float", finite_if)
assert_type("0.0 | finite-float", finite_tern)
assert_type("0.0 | finite-float", (if x.finite? then x else 0.0 end))
assert_type("0.0 | finite-float", x.finite? ? x : 0.0)
assert_type('"x" | numeric-string', x.finite? ? x.to_s : "x")

# `nan?` narrows only its falsey edge.
nan_if = if x.nan? then 0.0 else x end
nan_tern = x.nan? ? 0.0 : x
assert_type("0.0 | non-nan-float", x.nan? ? 0.0 : x)

# A comparison's falsey edge keeps the entry type: `!(x > 0.0)` is also true of NaN.
cmp_truthy_tern = x > 0.0 ? x : nil
cmp_falsey_if = if x > 0.0 then nil else x end
cmp_falsey_tern = x > 0.0 ? nil : x
assert_type("Float[0.0..]?", x > 0.0 ? x : nil)
assert_type("Float?", x > 0.0 ? nil : x)

nil_if = if s.nil? then "" else s end
nil_tern = s.nil? ? "" : s
assert_type('"" | String', s.nil? ? "" : s)

class_if = if v.is_a?(Integer) then v else 0 end
class_tern = v.is_a?(Integer) ? v : 0
assert_type("0 | 1", v.is_a?(Integer) ? v : 0)

empty_if = if a.empty? then nil else a end
empty_tern = a.empty? ? nil : a
assert_type("non-empty-array[String]?", a.empty? ? nil : a)

and_if = if s && x.finite? then [s, x] else nil end
and_tern = s && x.finite? ? [s, x] : nil
assert_type("[String, finite-float]?", s && x.finite? ? [s, x] : nil)

unless_modifier = (x unless x.nan?)
unless_block = unless x.nan? then x end
assert_type("non-nan-float?", (x unless x.nan?))
