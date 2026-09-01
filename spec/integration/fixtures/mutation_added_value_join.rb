require "rigor/testing"
include Rigor::Testing

# Issue #560 — a straight-line content mutation must JOIN the value it
# added into the carrier's element / value evidence.
#
# The mutation widening forgets the arity the mutation falsified, but it
# used to keep only the SEED's elements, so the widened carrier
# under-covered exactly the value the mutation put in. `u = [1, 2];
# u.push(6)` left `Array[1 | 2]`, `u.last` read back `1 | 2`, and the
# constant-comparison fold turned `u.last == 6` into `Constant[false]`:
# a false `flow.always-truthy-condition` on a program whose runtime
# value really IS 6. The block-capture path has joined appended evidence
# since ADR-56 slice C (`block_captured_writeback.rb`); this is the
# straight-line half.
#
# The companion project fixture `mutation_join_declared_sig/` pins the
# other side of the trade: the join must not grow a carrier past what a
# hand-written signature admits.

# --- The adders. The added value's type joins the seed's, so the read
# back covers it and nothing folds. ---
pushed = [1, 2]
pushed.push(6)
assert_type("Array[1 | 2 | Integer]", pushed)
assert_type("1 | 2 | Integer", pushed.last)

shoveled = [1, 2]
shoveled << 6
assert_type("Array[1 | 2 | Integer]", shoveled)

unshifted = [1, 2]
unshifted.unshift(9)
assert_type("Array[1 | 2 | Integer]", unshifted)

# --- The slot rewriters. PR #561 already widened the pinning here; the
# join keeps that and adds the stored value. For the compound form the
# stored value is the compound machinery's already-computed `t[0] + 5`. ---
compound = [1, 2]
compound[0] += 5
assert_type("Array[Integer]", compound)

slotted = [1, 2]
slotted[0] = 6
assert_type("Array[Integer]", slotted)

# --- An EMPTY seed has no element evidence to contradict, so the stored
# value joins precisely. This is mail's ragel-table shape (issue #533
# item 8): `stack = []; stack[top] = cs` read `Array[untyped]` before
# the join and reads the element type now. ---
stack = []
stack[1] = 42
assert_type("Array[Integer]", stack)

built = []
built.push("a")
assert_type("Array[String]", built)

# --- A HETEROGENEOUS add is the case the join must NOT claim precisely:
# the seed's class set does not admit `String`, so the added member takes
# the gradual floor rather than a foreign precise member. `Array[1 | 2 |
# Dynamic[top]]` still stops the stale fold — which is the point — while
# staying compatible with whatever the author declared. ---
mixed = [1, 2]
mixed << "s"
assert_type("Array[1 | 2 | Dynamic[top]]", mixed)

# --- Hash: the stored key and value join their own side's evidence. The
# key is admitted (Symbol seed, Symbol key); the value is not (the seed
# says FalseClass), so it floors. Redmine's `import.rb:274` is this
# shape — `csv_options = {:headers => false}` then
# `csv_options[:encoding] = enc`, read back and compared. ---
csv_options = { headers: false }
csv_options[:mode] = :fast
assert_type("Hash[Symbol, Dynamic[top] | FalseClass]", csv_options)

or_written = {}
or_written[:a] ||= 1
assert_type("Hash[Symbol, Integer]", or_written)

# --- Removers and reorderers add nothing, so they keep the pre-join
# arity-forget exactly: element evidence unchanged, shape forgotten. ---
popped = [1, 2]
popped.pop
assert_type("Array[1 | 2]", popped)

sorted = [1, 2]
sorted.sort!
assert_type("Array[1 | 2]", sorted)

# --- A collection NOBODY mutates keeps its exact literal Tuple: the
# join must not widen on the read path. ---
untouched = [1, 2]
assert_type("[1, 2]", untouched)

# ===================================================================
# The user-visible symptom. Every condition below is TRUE at runtime,
# and each one folded to a constant `false` before the join. None of
# them may draw a flow diagnostic.
# ===================================================================

fp_push = [1, 2]
fp_push.push(6)
puts "six" if fp_push.last == 6

fp_shovel = [1, 2]
fp_shovel << 6
puts "six" if fp_shovel.last == 6

fp_compound = [1, 2]
fp_compound[0] += 5
puts "six" if fp_compound[0] == 6

fp_slot = [1, 2]
fp_slot[0] = 6
puts "six" if fp_slot[0] == 6

fp_hash = { headers: false }
fp_hash[:encoding] = "UTF-8"
puts "utf" if fp_hash[:encoding] == "UTF-8"

# --- and the diagnostic must still fire where it is RIGHT. No mutation
# touches this array, so the comparison really is dead code. The spec
# keys the must-fire assertion on the marker below, so this stays the
# only flow diagnostic in the fixture. ---
genuine = [1, 2]
puts "never" if genuine[0] == 99 # GENUINE-FALSEY
