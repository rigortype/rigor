require "rigor/testing"
include Rigor::Testing

# ADR-56 slice C — a block that stores a value computed from the
# receiver's OWN contents. The seam used to type each stored value once,
# in the block-entry scope, where the receiver still holds its pre-call
# contents: `h[k] = h[k] + 1` stored `1` on every iteration as far as the
# join could tell, so three iterations read `Hash[…, 0 | 1]` and
# `h[:a] == 3` folded always-falsey on a program that prints "three".
# Every comparison below is TRUE at runtime unless it is marked. Each
# self-reading store is now iterated to a fixpoint and value-pin widened
# on the final pass.

# --- Hash: the stored value reads the receiver's own slot. ---
counts = { a: 0 }
%i[a a a].each { |k| counts[k] = counts[k] + 1 }
assert_type("Hash[Symbol, 0 | Integer]", counts)
puts "three" if counts[:a] == 3

# --- The `store` / `fetch` spelling of the same counter. ---
tally = { a: 0 }
%i[a a].each { |k| tally.store(k, tally.fetch(k) + 1) }
assert_type("Hash[Symbol, 0 | Integer]", tally)
puts "two" if tally[:a] == 2

# --- Array: the appended element reads the receiver's tail. ---
sums = [0]
[1, 2].each { |x| sums << (sums.last + x) }
assert_type("Array[0 | Integer]", sums)
puts "three" if sums.last == 3

# --- Array: the appended element reads the receiver's size. ---
sizes = [0]
[1, 2].each { sizes.push(sizes.size) }
assert_type("Array[0 | Integer]", sizes)
puts "two" if sizes.last == 2

# --- Array: a compound index write reads the slot it stores to. ---
slots = [0]
[1, 2].each { slots[0] += 1 }
assert_type("Array[0 | Integer]", slots)
puts "two" if slots[0] == 2

# --- `each_with_object`: the memo read back through its block alias. ---
memo = %i[a a].each_with_object({ a: 0 }) { |k, m| m[k] = m[k] + 1 }
assert_type("Hash[Symbol, 0 | Integer]", memo)
puts "two" if memo[:a] == 2

# --- A String the same block appends to. Its join is `String` whatever it
# stored, so a store that reads it sees `String`, never its pre-call
# value (which read `Array[0]` here). ---
buf = +""
lens = []
%w[ab cd].each do |w|
  buf << w
  lens << buf.length
end
assert_type("Array[non-negative-int]", lens)
puts "four" if lens.last == 4

# --- `each_with_object`: a memo store that reads a CAPTURED collection
# the same block mutates sees it at any iteration's entry, as the block
# seam's own stores do. ---
words = +""
widths = %w[ab cd].each_with_object([]) do |w, m|
  words << w
  m << words.length
end
assert_type("Array[non-negative-int]", widths)
puts "four" if widths.last == 4

run = [0]
seen = [1, 2].each_with_object([]) do |_x, m|
  run << (run.last + 1)
  m << run.last
end
assert_type("Array[Integer]", seen)
puts "two" if seen.last == 2

# --- A block PARAMETER mutated inside a nested block is not the outer
# local it shadows: the stores read the parameter, never the outer `[0]`,
# and the outer local's element joins none of the parameter's stores
# (the arity-forget still widens it, which only loses precision). ---
shade = [0]
firsts = []
[[1], [2]].each do |shade|
  [9].each { shade << 9 }
  firsts << shade.first
end
assert_type("Array[1 | 2]", firsts)
assert_type("Array[0]", shade)
puts "two" if firsts.last == 2

# --- A nested block's own parameter, one level deeper: the outer block's
# seam types `picks << inner.first` from its own entry scope, where
# `inner` would resolve to the outer local it shadows. It reads the
# parameter as unknown instead, never the outer `[0]`. ---
inner = [0]
picks = []
[1, 2].each do |v|
  [[v]].each do |inner|
    [9].each { inner << 9 }
    picks << inner.first
  end
end
assert_type("Array[Dynamic[top]]", picks)
assert_type("Array[0]", inner)
puts "two" if picks.last == 2

# --- A lazily initialised capture is still `nil` at the first
# iteration's entry, though the join drops that arm afterwards. ---
lazy = gets ? [0] : nil
nils = []
[1, 2].each do |v|
  nils << lazy.nil?
  lazy ||= []
  lazy << v
end
assert_type("Array[bool]", nils)
puts "true first" if nils.first == true

# --- A moving collection keeps its seed arm on every pass: `maybe` can
# still be nil on an iteration where `grow` has already grown, so
# `grow`'s store reads both arms. `maybe` itself continues as
# `Array[0 | Integer]` in the golden snapshot, which drops the nil it
# keeps at runtime when `gets` is nil — flip this when #1219 is fixed. ---
maybe = gets ? [0] : nil
grow = [0]
[1, 2].each do |_x|
  maybe << [grow].size if maybe
  grow << (maybe.nil? ? grow.size : -1)
end
assert_type("Array[0 | Integer]", grow)
puts "two" if grow.last == 2

# --- Evidence that grows structurally on every pass never converges, and
# the slot floors to its one-unknown-store answer: the seed's `[]` element
# survives beside `Dynamic[top]`. ---
nested = [[]]
[1, 2].each { nested << [nested.last] }
assert_type("Array[Dynamic[top] | []]", nested)

# --- Paired control: the same counter shape storing a value that does
# NOT read the receiver. Its evidence is complete after one pass, so the
# precise join stands and the comparison it rules out still folds —
# `fixed[:a]` is only ever 0 or 1. ---
fixed = { a: 0 }
%i[a a a].each { |k| fixed[k] = 1 }
assert_type("Hash[:a | Symbol, 0 | 1]", fixed)
puts "three" if fixed[:a] == 3 # GENUINE-FALSEY

# --- Paired control, mixed block: a store that reads nothing keeps its
# one-pass evidence beside a self-reading store — only a moving slot is
# widened — and the fold it supports still fires: `ones` only ever
# holds 1. ---
ones = []
tails = [0]
[1, 2].each do |x|
  ones << 1
  tails << (tails.last + x)
end
assert_type("Array[1]", ones)
assert_type("Array[0 | Integer]", tails)
puts "two" if ones.last == 2 # GENUINE-FALSEY

# --- Issue #586 / WD2.9: an empty accumulator filled from the block's
# element closes over the body's stores — no gradual arm. ---
acc = []
gets.to_s.split.map(&:to_i).each { |x| acc.push(x) }
assert_type("Array[Integer]", acc)
