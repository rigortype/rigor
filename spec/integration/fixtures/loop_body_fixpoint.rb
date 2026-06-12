require "rigor/testing"
include Rigor::Testing

# ADR-56 slice B — loop-body fixpoint widening. A `while` / `until` body
# runs 0..N times and may compound, but the engine historically joined
# the pre-loop scope with a SINGLE body pass, so an accumulator kept a
# stale folded constant (`d = 1; while …; d *= 2; end` → `1 | 2`, never
# reaching the runtime `4, 8, …`) — a spec-MUST violation in
# § "Fact stability and mutation". The fixpoint folds each body-written
# local's continuation binding through the same capped iteration slice A
# uses for non-escaping block captures. Each dumped local is the
# loop-carried variable itself, chosen to discriminate the write-back.

# --- `while` accumulator (`*=`): widens to the nominal base, never the
# unsound `1 | 2`. The co-varying counter `i` also accumulates. ---
d = 1
i = 0
while i < 3
  d *= 2
  i += 1
end
assert_type("Integer", d)
# Item 4 — the `while i < 3` loop exits precisely on its falsey edge,
# so the post-loop counter carries the exit refinement `int<3, max>`
# (`i >= 3`), a strict precision gain over the bare `Integer`.
assert_type("int<3, max>", i)

# --- `+=` accumulator. ---
total = 0
n = 0
while n < 5
  total += n
  n += 1
end
assert_type("Integer", total)

# --- `until` variant: same fixpoint over the inverted predicate. ---
a = 1
j = 0
until j >= 3
  a *= 2
  j += 1
end
assert_type("Integer", a)

# --- `begin … end while` (do-loop, body runs at least once): the
# widening is identical — the fixpoint does not depend on the
# pre-test / post-test distinction. ---
b = 1
k = 0
begin
  b += 1
  k += 1
end while k < 3
assert_type("Integer", b)

# --- Body-FIRST assignment: a local first bound INSIDE the loop body has
# no pre-loop binding, so the 0-iteration path (the body may never run)
# degrades it to `T | nil`. ---
counter = 0
while counter < 2
  fresh = counter * 2
  counter += 1
end
assert_type("Integer?", fresh)

# --- Receiver CONTENT mutation of a NON-rebound local: the slice-B
# fixpoint overlays only the locals the body REBINDS (here the counter
# `m`); the slice-C content writeback then JOINS the pushed element type
# (`m` → `Integer`) into `acc`'s element parameter. Pre-slice-C this read
# the imprecise-but-sound `Array[Dynamic[top]] | []`; slice C tightens it
# to `Array[Integer]` (the pushed value's widened type). ---
acc = []
m = 0
while m < 3
  acc.push(m)
  m += 1
end
assert_type("Array[Integer]", acc)

# --- Loop with `break`: the sound widening applies (the accumulator
# still compounds), and the break / exit-edge behaviour is preserved —
# the body still evaluates from the post-predicate scope. ---
c = 1
p = 0
while p < 10
  c *= 2
  break if p > 1

  p += 1
end
assert_type("Integer", c)

# --- Compounding shape (`g = [g]`) grows structurally each pass and
# cannot converge even under value-pinned widening, so it floors to the
# established `Dynamic[top]` after the cap — the same collapse slice A's
# block captures use. ---
g = 1
q = 0
while q < 3
  g = [g]
  q += 1
end
assert_type("Dynamic[top]", g)
