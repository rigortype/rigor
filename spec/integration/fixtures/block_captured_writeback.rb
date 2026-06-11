require "rigor/testing"
include Rigor::Testing

# ADR-56 slice A — non-escaping block captured-local write-back. A
# `:non_escaping` block (each / times / upto …) that rebinds an outer
# local must NOT leave that local's pre-call binding unmodified in the
# continuation scope. Before this slice every assertion below was a
# WRONG constant (`Constant[1]` / `"x"`), a spec-MUST violation in
# § "Fact stability and mutation". Each shape is chosen to discriminate
# the write-back from RBS return absorption: the dumped local is the
# block-captured variable itself, not an expression downstream of it.

# --- Integer accumulators (`*=` / `+=`) widen to a base. The `upto`
# bound flows a fresh constant into `power` each pass; without the
# fixpoint widening it would stay `Constant[1]`. ---
power = 1
1.upto(6) { power *= 2 }
assert_type("Integer", power)

# `upto` flows the bounded-int refinement (`int<1, 6>`) into the block
# param, so `fact *= i` multiplies the running fixpoint assumption
# (`1 | int<1, 6>`) by a refinement. The mixed `Constant | IntegerRange`
# union must fold as the bounding interval (not bail to `Dynamic[top]`),
# otherwise the accumulator never converges below the cap floor.
fact = 1
1.upto(6) { |i| fact *= i }
assert_type("Integer", fact)

# A param-driven accumulator (`each`'s element is `Integer`) over `+=`.
total = 1
[1, 2, 3].each { |i| total += i }
assert_type("Integer", total)

# `times` accumulator. Sound widening, never the wrong `Constant[0]`.
counter = 0
3.times { counter += 1 }
assert_type("Integer", counter)

# --- Plain `=` rebind to a distinct constant keeps both pinned
# constituents (it converges before the widening iteration): the
# pre-call binding stays a constituent for the 0-iteration path, the
# rebind contributes its own. ---
flag = 1
[1].each { flag = 99 }
assert_type("1 | 99", flag)

# --- String accumulation widens to `String`. ---
buffer = "x"
[1].each { buffer += "y" }
assert_type("String", buffer)

# --- Multi-assign target (`x, y = ...`) — both targets written. ---
left = 1
right = 2
[1].each { left, right = right, left }
assert_type("1 | 2", left)
assert_type("1 | 2", right)

# --- `||=` — the 0-iteration path keeps the pre-call `nil`. ---
memo = nil
[1].each { memo ||= 5 }
assert_type("5?", memo)

# --- No-write block: the captured local that the block only READS keeps
# its EXACT pre-call constant — the fast path must be byte-identical to
# pre-slice behaviour. ---
untouched = 7
[1].each { |z| z.to_s }
assert_type("7", untouched)

# --- Compounding shape (`a = [a]`) cannot converge even under
# value-pinned widening — it grows structurally each pass — so it floors
# to the established escaping-block `Dynamic[top]` after the cap. ---
growing = 1
[1].each { growing = [growing] }
assert_type("Dynamic[top]", growing)

# --- An escaping block is unchanged: its captured-local write was
# already dropped to `Dynamic[top]` by `record_closure_escape_if_any`
# (the closure may run later, an unknown number of times). `then`
# yielding the block to an unknown sink is the simplest escape shape we
# model conservatively. ---
escaped = 1
define_method(:sink) { escaped = 42 }
assert_type("Dynamic[top]", escaped)
