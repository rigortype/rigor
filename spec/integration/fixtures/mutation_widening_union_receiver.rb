require "rigor/testing"
include Rigor::Testing

# Issue #645 — a straight-line content mutation on a UNION receiver used
# to record nothing at all: `widen_for_mutator` declined a `Union`
# outright, so the literal member kept the arity the mutation had just
# falsified. `out = flag ? 5 : [2]; out << 2` answered `5 | [2]` on a
# program whose array branch holds `[2, 2]`, and a later `out.size == 1`
# or `out.last == 2` folded on a value the program never holds.
#
# The union is now mapped MEMBERWISE, on the partition #631 drew for the
# block seam: a member the mutator's class carries widens exactly as the
# non-union path widens it, every other member survives whole.

# --- The issue's own shape. The foreign `5` arm is untouched; the Tuple
# arm loses its arity and gains the appended value's evidence. ---
def union_seed(flag)
  out = flag ? 5 : [2]
  out << 2
  assert_type("5 | Array[2 | Dynamic[top] | Integer]", out)
  puts "one" if out.size == 1
  out
end

# --- Every carrier member widens, not just the first one found. ---
def union_of_tuples(flag)
  xs = flag ? [1] : [2, 3]
  xs << 9
  assert_type("Array[1 | Dynamic[top] | Integer] | Array[2 | 3 | Dynamic[top] | Integer]", xs)
  xs
end

# --- The Hash carrier takes the same treatment through its own table. ---
def union_hash_seed(flag)
  h = flag ? 5 : { a: 1 }
  h[:b] = 2
  assert_type("5 | Hash[Dynamic[top] | Symbol, Dynamic[top] | Integer]", h)
  h
end

# --- A union with NO member the mutator's class carries is untouched:
# `String#<<` is in neither table, so nothing about this binding was
# falsified and the precise members survive. ---
def union_no_carrier(flag)
  y = flag ? 5 : "s"
  y << "t"
  assert_type("5 | String", y)
  y
end

# --- The must-still-fire control. Nothing mutates this binding, so the
# arity fold is correct and has to survive; without it the silence above
# could be a rule that stopped firing. ---
def unmutated_tuple_still_folds
  kept = [1]
  puts "one" if kept.size == 1 # GENUINE-TRUTHY
  kept
end
