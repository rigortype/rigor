require "rigor/testing"
include Rigor::Testing

# Issue #3337 — ADR-56 slice C, the loop seam's ARGUMENT side. A store in a
# `while` / `until` body is typed with each local the loop rebinds at the
# binding the body pass reached the store with, not at its post-loop
# binding: that one carries the `nil` the zero-iteration path seeds a
# body-first local with, and on that path the store never ran. Each
# section says what Ruby 4.0.5 leaves in the collection.

# --- The issue's shape: `["a", "a", "a"]`. ---
out = []
i = 0
while i < 3
  s = ENV.fetch("X", "a")
  out << s
  i += 1
end
assert_type("Array[String]", out)

# --- A rebind AFTER the store is not what the store pushed:
# `["a", "a", "a"]`, never `[nil, …]`. ---
later_nil = []
i = 0
while i < 3
  s = ENV.fetch("X", "a")
  later_nil << s
  s = nil
  i += 1
end
assert_type("Array[String]", later_nil)

# --- No loop-carried counter, so the fixpoint settles before its cap and
# the store keeps the value pin: `["a", …]`. ---
pinned = []
while rand > 0.5
  lit = "a"
  pinned << lit
end
assert_type("Array[\"a\"]", pinned)

# --- A value that really can be nil stays nilable: `ENV["X"]`. ---
real_nil = []
i = 0
while i < 3
  s = ENV["X"]
  real_nil << s
  i += 1
end
assert_type("Array[String?]", real_nil)

# --- Assigned on some iterations only: `[nil, "a", …]` — the first
# iteration pushes the `nil` the local still holds. ---
some = []
i = 0
while i < 3
  w = "a" if rand > 0.5
  some << w
  i += 1
end
assert_type("Array[String?]", some)

# --- The same, decided by the loop-carried counter: `[nil, nil, "a"]`.
# `i > 1` folds to `false` under the fixpoint's first value-pinned
# assumptions, so `v` first moves on the capped pass and floors to
# `Dynamic[top]` (`BodyFixpoint`); the store keeps that floor. ---
late = []
i = 0
while i < 3
  v = "a" if i > 1
  late << v
  i += 1
end
assert_type("Array[Dynamic[top]]", late)

# --- A guard narrows the store's argument: `["a"]`. ---
guarded = []
i = 0
while i < 3
  g = ENV["X"]
  guarded << g if g
  i += 1
end
assert_type("Array[String]", guarded)

# --- A path that skips this iteration's assignment pushes what an EARLIER
# iteration left: `[1, "x", 1, "x"]`. ---
carried = []
i = 0
while i < 4
  if rand > 0.5 then c = 1 end
  carried << c
  c = "x"
  i += 1
end
assert_type("Array[Integer | String | nil]", carried)

# --- Stored on a path the body pass reaches with the local unbound:
# `[1, 1]`. There is no binding at the store to read, so the store keeps
# the continuation binding and its `nil`. ---
unbound = []
i = 0
while i < 3
  if i == 0 then e = 1 else unbound << e end
  i += 1
end
assert_type("Array[Integer?]", unbound)

# --- Assigned before the loop and again in it: `["a", "a"]`; the pre-loop
# `nil` was never stored. ---
pre = nil
reassigned = []
i = 0
while i < 2
  pre = ENV.fetch("X", "a")
  reassigned << pre
  i += 1
end
assert_type("Array[String]", reassigned)

# --- Stored BEFORE the assignment in the body: `[nil, "a"]` — the first
# iteration pushes the pre-loop `nil`. ---
first = nil
stored_first = []
i = 0
while i < 2
  stored_first << first
  first = ENV.fetch("X", "a")
  i += 1
end
assert_type("Array[String?]", stored_first)

# --- The loop-carried value itself: `[0, 1, 2]`, never the `0 | 1 | 2`
# the capped pass happened to see. ---
counted = []
i = 0
while i < 3
  n = i
  counted << n
  i += 1
end
assert_type("Array[Integer]", counted)

# --- `until`, and a `begin … end while` body. ---
u = []
i = 0
until i >= 3
  s = ENV.fetch("X", "a")
  u << s
  i += 1
end
assert_type("Array[String]", u)

b = []
i = 0
begin
  s = ENV.fetch("X", "a")
  b << s
  i += 1
end while i < 3
assert_type("Array[String]", b)

# --- The other stores the seam reads. ---
by_index = {}
i = 0
while i < 3
  s = ENV.fetch("X", "a")
  by_index[i] = s
  i += 1
end
assert_type("Hash[Integer, String]", by_index)

by_key = {}
i = 0
while i < 3
  s = ENV.fetch("X", "a")
  by_key.store(s, i)
  i += 1
end
assert_type("Hash[String, Integer]", by_key)

pushed = []
i = 0
while i < 3
  s = ENV.fetch("X", "a")
  t = i.to_s
  pushed.push(s, t)
  i += 1
end
assert_type("Array[String]", pushed)

unshifted = []
i = 0
while i < 3
  s = ENV.fetch("X", "a")
  unshifted.unshift(s)
  i += 1
end
assert_type("Array[String]", unshifted)

slots = []
i = 0
while i < 3
  s = ENV.fetch("X", "a")
  slots[i] = s
  i += 1
end
assert_type("Array[String]", slots)

keyed = {}
i = 0
while i < 3
  k = ENV.fetch("X", "a")
  keyed[k] ||= 1
  i += 1
end
assert_type("Hash[String, Dynamic[top]]", keyed)

# --- A store in a block the body calls: `["A", "B", "A", "B"]`. The loop
# counts the block's `t` among the locals its body first assigns. ---
in_block = []
i = 0
while i < 2
  %w[a b].each { |x| t = x.upcase; in_block << t }
  i += 1
end
assert_type("Array[String]", in_block)

# --- A store in a nested loop is typed for both loops. ---
nested = []
i = 0
while i < 3
  j = 0
  while j < 2
    inner = ENV.fetch("X", "a")
    nested << inner
    j += 1
  end
  i += 1
end
assert_type("Array[String]", nested)

# --- The inner loop's counter caps its fixpoint and the outer loop's
# settles: `[0, 1, 0, 1]`. The outer join reads `m` as the inner loop
# settled it, not at the `0 | 1 | 2` of the inner loop's last pass. ---
settled = []
while rand > 0.5
  j = 0
  while j < 2
    m = j
    settled << m
    j += 1
  end
end
assert_type("Array[Integer]", settled)

# --- A seed that is an Array or a Hash, and one that is an Array or a
# String: each member's join reads the store the same way. ---
either = rand > 0.5 ? [] : {}
i = 0
while i < 3
  s = ENV.fetch("X", "a")
  either.store(s, i) if either.is_a?(Hash)
  i += 1
end
assert_type("Array[Dynamic[top]] | Hash[String, Integer]", either)

text_or_list = rand > 0.5 ? [] : +"ab"
i = 0
while i < 3
  s = ENV.fetch("X", "a")
  text_or_list << s
  i += 1
end
assert_type("Array[String] | String", text_or_list)

# --- A collection built in the body and stored: `[[1, 2], [1, 2]]`. The
# store keeps the local's later contents beside what it held at the store,
# since the stored object is the one the body goes on mutating; the `nil`
# of the zero-iteration path is gone. ---
rows = []
i = 0
while i < 2
  row = [1]
  rows << row
  row << 2
  i += 1
end
assert_type("Array[Array[1 | Dynamic[top] | Integer] | [1]]", rows)
