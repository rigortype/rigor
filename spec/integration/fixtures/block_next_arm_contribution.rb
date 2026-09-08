require "rigor/testing"
include Rigor::Testing

# Issue #841 — `next value` arms contribute to a block's value type.
# The block-return pass previously modelled only the fall-through tail,
# so a predicate block shaped `next false unless cond; ...; true` read
# as `Constant[true]` and BlockFolding folded the enclosing `all?` to
# `Constant[true]` — a `flow.always-truthy-condition` on correct code.
# The fix joins every reachable `next` arm with the tail, exactly as
# explicit_return_contribution.rb does one level up for `return`.

# A non-constant argument source. A literal `true` would narrow the
# guard predicate to a known truthy/falsey value, making the `next` arm
# provably dead (correctly pruned, so it would not contribute) —
# defeating the point of these assertions.
def some_bool = [true, false].sample

# THE ISSUE'S SHAPE. `all?` over an untyped receiver folded to
# `Constant[true]` off the tail alone; with the falsey arm joined, the
# block is no longer a constant and the predicate defers to `bool`.
def all_present?(ops)
  ops.all? do |o|
    next false unless o

    true
  end
end

assert_type("bool", all_present?([1, nil]))

# The reported SYMPTOM, not just the type: without the join this
# condition reads as a flow constant and `flow.always-truthy-condition`
# fires on a call that really can answer false.
puts "yes" if all_present?([1, nil])

# The must-still-fold control: no falsey arm, so `all?` really is
# unconditionally true and the fold must survive. Asserted as a TYPE
# rather than as a condition, so the "no flow warning fires" assertion
# above stays about the joined predicate alone.
def all_true?(ops)
  ops.all? do |_o|
    true
  end
end

assert_type("true", all_true?([1, nil]))

# A bare `next` contributes nil; the tail is an Integer.
# `Mutex#synchronize` is `[X] () { () -> X } -> X`, so the call's type
# IS the block's value type.
def maybe_int(flag)
  m = Mutex.new
  m.synchronize do
    next if flag

    42
  end
end

assert_type("42?", maybe_int(some_bool))

# The arm is typed in the scope that reaches it, not the block's entry
# scope: `v` is a String by the time the `next` runs.
def rebound_arm(flag)
  m = Mutex.new
  v = 1
  m.synchronize do
    v = "s"
    next v if flag

    42
  end
end

assert_type('"s" | 42', rebound_arm(some_bool))

# A `next` a nested block owns ends THAT iteration; it cannot carry a
# value out of the outer block, so it must not join.
def nested_block_next
  m = Mutex.new
  m.synchronize do
    [1, 2].each { next 1 }
    42
  end
end

assert_type("42", nested_block_next)

# A loop consumes `next` as "continue" — same barrier rule.
def loop_next(flag)
  m = Mutex.new
  m.synchronize do
    next 5 while flag
    42
  end
end

assert_type("42", loop_next(some_bool))

# A multi-value `next a, b` ends the invocation with the array `[a, b]`,
# matching `return a, b`.
def multi_value_arm(flag)
  m = Mutex.new
  m.synchronize do
    next 1, "x" if flag

    42
  end
end

assert_type('42 | [1, "x"]', multi_value_arm(some_bool))

# Flow sensitivity comes free from the evaluator's dead-arm skip: `x` is
# pinned per position, so `x.nil?` folds to false and the arm is never
# entered. A join that widened every guarded `next` unconditionally
# would answer `["1"?, "2"?]` here.
assert_type('["1", "2"]', [1, 2].map do |x|
  next nil if x.nil?

  x.to_s
end)
