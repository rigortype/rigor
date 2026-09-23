require "rigor/testing"
include Rigor::Testing

# ADR-56 slice C — a block store whose value reads an outer local the
# SAME body rebinds. The join typed each store's evidence in the
# block-entry scope, which binds a captured local where the call found
# it: `out << total` stored the pre-call `0` on every iteration as far as
# the join could tell, `out` read `Array[0]`, and `out.last == 3` folded
# always-falsey on a program whose `out` is `[1, 3]`. The evidence is now
# also typed with such a local at slice A's continuation binding, and the
# two answers are joined. Every comparison below is TRUE at runtime
# unless it is marked.

# --- Array: the appended value is a running total. ---
total = 0
out = []
[1, 2].each do |x|
  total += x
  out << total
end
assert_type("Array[0 | Integer]", out)
puts "three" if out.last == 3

# --- Hash: the stored value is a running total. ---
run = 0
latest = { a: 0 }
[1, 2].each do |x|
  run += x
  latest[:a] = run
end
assert_type("Hash[:a | Symbol, 0 | Integer]", latest)
puts "three" if latest[:a] == 3

# --- `each_with_object`: the memo stores a running total. ---
sum = 0
memo = [1, 2].each_with_object([]) do |x, m|
  sum += x
  m << sum
end
assert_type("Array[0 | Integer]", memo)
puts "three" if memo.last == 3

# --- The same memo on a receiver Rigor cannot prove non-escaping reads the
# rebound local at the escaping-block floor. ---
def running(xs)
  count = 0
  r = xs.each_with_object([]) do |_x, m|
    count += 1
    m << count
  end
  puts "two" if r.last == 2
end
running([1, 2])

# --- A read between two rebinds sees neither binding slice A computes.
# Typed under `nil | :done`, `state.length` would answer `4`; typed under
# the pre-call `nil` alone it is `Dynamic[top]`, and the join keeps that
# arm, so nothing folds. ---
state = nil
lengths = []
%w[a bb].each do |s|
  state = s
  lengths << state.length
  state = :done
end
puts "two" if lengths.last == 2

# --- Residue: slice A drops the scope at `next`, so the value carried out
# of an iteration only through it reaches no binding. Runtime `stepped` is
# `[0, 1, 2]`. Flip this when #1214 is fixed. ---
step = 0
stepped = []
[1, 2, 3].each do |x|
  stepped << step
  step = x
  next if x > 0

  step = 0
end
assert_type("Array[0]", stepped)

# --- A block parameter still shadows the outer local it names: the store
# reads the yielded element, never the outer "s", though the body writes
# the name. ---
shadow = "s"
got = []
[1, 2].each do |shadow|
  got << shadow
  shadow = nil
end
assert_type("Array[1 | 2]", got)
puts "two" if got.last == 2

# --- Paired control: the rebound local only ever holds 0 or 1, so the
# evidence stays precise and the comparison it rules out still folds. ---
flag = 0
seen = []
[1, 2].each do
  flag = 1
  seen << flag
end
assert_type("Array[0 | 1]", seen)
puts "two" if seen.last == 2 # GENUINE-FALSEY
