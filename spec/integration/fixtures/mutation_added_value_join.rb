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
# value joins precisely. An Array survives the widening's one-way door
# (only the FIRST store ever reaches a join) because its element
# parameter is a union over POSITIONS: a missed store leaves it merely
# incomplete. The Hash section below is where that stops being true. ---
stack = []
stack[1] = 42
assert_type("Array[Integer]", stack)

built = []
built.push("a")
assert_type("Array[String]", built)

# --- A seed slot the engine cannot type is EVIDENCE ("this slot holds
# something unknown"), and reaches the same gradual answer by a
# different route. The two must not be conflated on the way IN: read
# off the widened carrier both `[]` and `[x]` are `Array[Dynamic[top]]`,
# and only the pre-state literal tells them apart. ---
def gradual_seed(x)
  from_dynamic = [x]
  from_dynamic.push(1)
  assert_type("Array[Dynamic[top] | Integer]", from_dynamic)
end

# --- A HETEROGENEOUS add is the case the join must NOT claim precisely:
# the seed's class set does not admit `String`, so the added member takes
# the gradual floor rather than a foreign precise member. `Array[1 | 2 |
# Dynamic[top]]` still stops the stale fold — which is the point — while
# staying compatible with whatever the author declared. ---
mixed = [1, 2]
mixed << "s"
assert_type("Array[1 | 2 | Dynamic[top]]", mixed)

# --- Hash: the stored key and value join their own side's evidence, and
# BOTH parameters then stay gradual. Only the first store into a hash
# ever reaches a join (the widening leaves a Nominal, which is declined),
# and a Hash's parameters are unions over KEYS that a read selects one
# of — so closing them makes the read a wrong type for every key the
# missed stores wrote. Redmine's `import.rb:274` is this shape —
# `csv_options = {:headers => false}` then `csv_options[:encoding] =
# enc`, read back and compared. ---
csv_options = { headers: false }
csv_options[:mode] = :fast
assert_type("Hash[Dynamic[top] | Symbol, Dynamic[top] | FalseClass]", csv_options)

or_written = {}
or_written[:a] ||= 1
assert_type("Hash[Dynamic[top] | Symbol, Dynamic[top] | Integer]", or_written)

# --- mail's `Message#to_yaml`, the shape that pinned the open-parameter
# rule down. Several straight-line stores into a hash seeded `{}`, then
# an Array stored under one key and appended to through the READ. Only
# the FIRST store reaches the join (the widening leaves a Nominal, which
# `widen_for_mutator` declines), so a precise value parameter would carry
# the `{}` store's Hash arm and have DROPPED the `[]` store's Array arm —
# and `<<` on the read drew `undefined method '<<' for Hash[...]` on a
# program that is right by construction. Both the block form and the
# straight-line form must stay silent, and the conditional form too:
# the three separate a scoping bug from an evidence bug. ---
def to_yaml_shape(parts, multipart)
  hash = {}
  hash["headers"] = {}
  hash["transport_encoding"] = "7bit"
  if multipart
    hash["multipart_body"] = []
    parts.map { |part| hash["multipart_body"] << part }
  end
  hash
end

def to_yaml_unconditional(parts)
  hash = {}
  hash["headers"] = {}
  hash["multipart_body"] = []
  parts.map { |part| hash["multipart_body"] << part }
  hash
end

def to_yaml_straight_line(part)
  hash = {}
  hash["headers"] = {}
  hash["multipart_body"] = []
  hash["multipart_body"] << part
  hash
end

# --- and the must-still-fire sibling: a value the seed pins to a class
# with no `<<`, where NO store ever put an appendable there. The literal
# shape survives (no mutator ran), so the read is the pinned member and
# the diagnostic is right. Without this case the three above would pass
# on a rule that had simply stopped firing. ---
def never_appendable
  pinned = { name: :tag }
  pinned[:name] << 2 # GENUINE-UNDEFINED
  pinned
end

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
