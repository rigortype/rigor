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

# --- Issue #586 / WD2.9: an empty accumulator filled from the block's
# element closes over the body's stores — no gradual arm. ---
acc = []
gets.to_s.split.map(&:to_i).each { |x| acc.push(x) }
assert_type("Array[Integer]", acc)
