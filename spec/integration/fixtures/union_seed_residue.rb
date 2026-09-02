require "rigor/testing"
include Rigor::Testing

# Issue #631 — the block / loop content seam REPLACES the binding with
# one freshly built `Nominal[Array]` / `Nominal[Hash]`, and that answer
# is right only for the pre-state members the mutation applied to as a
# collection of that class. A `Union` seed can carry members that are
# not collection carriers at all — a whole-variable `Dynamic`, a
# foreign `Nominal`, a `Constant` — and those contribute no element /
# key / value evidence, so they used to vanish.
#
# This is ADR-56 WD2.9 one level out: there the surviving `Dynamic` was
# an ELEMENT of an Array carrier, here it is the whole variable. Both
# say the same thing — the body's stores are evidence about what the
# body PUT IN, never about what the variable WAS. The straight-line
# seam already read such a union through untouched, so the block and
# loop seams were the outliers.

# --- Must-not-fire: the whole-variable `Dynamic` arm survives. `u` is
# untyped, so `out.first.upcase` is correct code whenever the caller
# passes an array of strings. Before the residue rule the seam read
# `Array[2]` and drew `undefined method 'upcase' for 2`. ---
def block_keeps_the_dynamic_arm(flag, u)
  out = flag ? u : [2]
  [1].each { out << 2 }
  assert_type("Array[2] | Dynamic[top]", out)
  out.first.upcase
end

# The same drop seen from the constant-fold side: a closed `Array[2]`
# folds `out.first == 3` to `Constant[false]` and draws a false
# `flow.always-truthy-condition`. A union carrying `Dynamic` cannot
# fold, so the branch stays live.
def block_keeps_the_fold_open(flag, u)
  out = flag ? u : [2]
  [1].each { out << 2 }
  puts "hit" if out.first == 3
end

# The `while` twin — the loop seam shares the join, and dropped the arm
# identically.
def loop_keeps_the_dynamic_arm(flag, u)
  out = flag ? u : [2]
  i = 0
  while i < 2
    out << 2
    i += 1
  end
  assert_type("Array[2] | Dynamic[top]", out)
  out.first.upcase
end

# The Hash twin, through the `[]=` adder.
def block_keeps_the_dynamic_arm_hash(flag, u)
  out = flag ? u : { a: 1 }
  [1].each { out[:b] = 2 }
  assert_type("Dynamic[top] | Hash[:b | Symbol, 1 | 2]", out)
  out[:a].upcase
end

# A member the engine DOES have a name for is kept for the same reason:
# the seam cannot say `Bag` was mutated as an Array, so it must not
# rewrite it.
class Bag
  def <<(_other)
    self
  end
end

def block_keeps_a_foreign_nominal_arm(flag)
  out = flag ? Bag.new : [2]
  [1].each { out << 2 }
  assert_type("Array[2] | Bag", out)
end

# --- Must-still-succeed. A plain empty seed has no member to keep, so
# the body's stores still CLOSE it: without this the fixture would pass
# on a seam that had gone gradual everywhere. ---
def closes_a_plain_seed
  acc = []
  [1].each { acc << 1 }
  assert_type("Array[1]", acc)
  acc.first.upcase # GENUINE-UNDEFINED
end

# Two Array carriers in the pre-state still join to ONE Array: both are
# carriers, both contribute elements, neither is residue. The exact
# `assert_type` is the discrimination — a residue rule that kept a
# carrier would read `Array[1 | 3] | Array[2 | 3]` here.
def joins_two_array_carriers(flag)
  out = flag ? [1] : [2]
  [1].each { out << 3 }
  assert_type("Array[1 | 2 | 3]", out)
end

# `Array.new` types as a BARE `Nominal[Array]` with no type args, which
# yields no element evidence — but it is still a carrier, so it is
# absorbed rather than kept as a second arm (issue #615's seed keeps
# closing; the rule does not double-widen).
def absorbs_a_bare_array_carrier(flag)
  out = flag ? Array.new : [2]
  [1].each { out << 3 }
  assert_type("Array[2 | 3]", out)
end

# --- The nil arm is the one member the mutation itself refutes:
# `NilClass` defines no content mutator, so on every path where the
# body ran the binding was not nil. Only the zero-iteration path keeps
# it, and that path is modelled upstream, not here. The live nil arm is
# still reported once — at the mutation, below. ---
def drops_the_refuted_nil_arm(flag)
  out = flag ? nil : [2]
  [1].each { out << 2 } # GENUINE-NIL
  assert_type("Array[2]", out)
  out.first.upcase # GENUINE-UNDEFINED
end
