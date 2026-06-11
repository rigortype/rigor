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

# ===================================================================
# ADR-56 slice C — receiver-content element-type JOIN. The block body
# CONTENT-mutates a captured collection (`out << x`) rather than
# rebinding it. Before this slice a NON-EMPTY seed kept only the seed's
# elements (`Array[0]` for a really-`[0, 1, 2, 3]` array — UNSOUND, the
# B1 survey bug: `out.first.zero?` folded to a wrong `true`). The
# appended / stored types must JOIN into the element / key / value
# parameter.
# ===================================================================

# --- Non-empty Array seed: the appended element joins the seed element
# (B1 — the unsound case). Pre-slice this was `Array[0]`. ---
out = [0]
[1, 2, 3].each { |x| out << x }
assert_type("Array[0 | 1 | 2 | 3]", out)

# --- and the wrong constant fold it caused is gone: `first` over the
# joined array is the element union, not the seed's `0`. ---
assert_type("0 | 1 | 2 | 3", out.first)

# --- Empty Array seed built by `<<` of a computed element (B4): the
# `Dynamic[top]` floor is dropped once real element evidence exists. ---
built = []
[1, 2, 3].each { |x| built << (x * 2) }
assert_type("Array[2 | 4 | 6]", built)

# --- `push` form of the same. ---
pushed = []
[1, 2, 3].each { |x| pushed.push(x) }
assert_type("Array[1 | 2 | 3]", pushed)

# --- `concat` of a literal pair joins both elements. ---
catted = [0]
[1, 2, 3].each { |x| catted.concat([x, x + 1]) }
assert_type("Array[0 | 1 | 2 | 3 | 4]", catted)

# --- Hash `[]=` joins key and value parameters (the canonical build-a-
# hash idiom). ---
table = {}
[1, 2, 3].each { |x| table[x] = x.to_s }
assert_type('Hash[1 | 2 | 3, "1" | "2" | "3"]', table)

# --- String accumulation via `<<` widens to the nominal base (String
# carries no element parameter; the constant value is no longer sound). ---
sbuf = "a"
[1, 2, 3].each { |x| sbuf << x.to_s }
assert_type("String", sbuf)

# --- Nested `h[k] ||= []; h[k] << v` — the appended values land on the
# NESTED array, but `h` itself is content-mutated through the index-write,
# so it must NOT stay an empty `{}` (which would fold `h.empty?` to a
# wrong `true`). The value floors to `Dynamic[top]` (opaque), keys join. ---
groups = {}
[1, 2, 3].each do |x|
  groups[x] ||= []
  groups[x] << x
end
assert_type("Hash[1 | 2 | 3, Dynamic[top]]", groups)

# --- `each_with_object` adopts the joined memo type as its RETURN (B3),
# both the Array and Hash memo forms. Pre-slice these were `Dynamic[top]`. ---
ewo_arr = [1, 2, 3].each_with_object([]) { |x, acc| acc << (x * 2) }
assert_type("Array[2 | 4 | 6]", ewo_arr)

ewo_hash = [1, 2, 3].each_with_object({}) { |x, h| h[x] = x * 2 }
assert_type("Hash[1 | 2 | 3, 2 | 4 | 6]", ewo_hash)

# --- A non-content-mutation block over a collection stays byte-identical:
# the block only READS the captured local, so its exact literal Tuple is
# preserved (no spurious widening from the slice-C walk). ---
readonly = [1, 2]
[1, 2, 3].each { |x| x + 1 }
assert_type("[1, 2]", readonly)
