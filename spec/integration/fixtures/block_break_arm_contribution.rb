require "rigor/testing"
include Rigor::Testing

# Issue #853 — a block-level `break value` is the yielding CALL's value.
# The call was typed from the callee's result alone, so a predicate block
# shaped `break false unless cond; ...; true` folded the enclosing `all?`
# to `Constant[true]` and drew a `flow.always-truthy-condition` on correct
# code. The fix unions every reachable `break` arm into the CALL's type —
# the sibling of #841's `next` join one level down, routed to the other
# construct because `break` leaves the call, not the block.

# A non-constant argument source. A literal would let the guard fold, and
# a provably dead `break` arm is correctly never reached — defeating the
# point of these assertions.
def some_bool = [true, false].sample

# THE ISSUE'S SHAPE. `all?` still folds its no-break path to `true`; the
# union with the `false` arm is what makes the call `bool`.
def all_present?(ops)
  ops.all? do |o|
    break false unless o

    true
  end
end

assert_type("bool", all_present?([1, nil]))

# The reported SYMPTOM, not just the type: without the union this
# condition reads as a flow constant and `flow.always-truthy-condition`
# fires on a call that really can answer false.
puts "yes" if all_present?([1, nil])

# The must-still-fold control: no break arm, so `all?` really is
# unconditionally true and the fold must survive.
def all_true?(ops)
  ops.all? do |_o|
    true
  end
end

assert_type("true", all_true?([1, nil]))

# `each` returns its receiver; a `break` arm adds the value it carries.
def each_with_break(xs, flag)
  xs.each do |_x|
    break 7 if flag
  end
end

assert_type("7 | Array", each_with_break([1, 2], some_bool))

# A bare `break` carries nil, so the call becomes optional.
def each_with_bare_break(xs, flag)
  xs.each do |_x|
    break if flag
  end
end

assert_type("Array?", each_with_bare_break([1, 2], some_bool))

# `find` answers an element or nil; the arm joins that. The Tuple
# receiver folds the element side to `1` — the first position, which is
# where a `positive?` predicate first answers true.
def find_with_break(xs, flag)
  xs.find do |x|
    break "b" if flag

    x.positive?
  end
end

assert_type('"b" | 1', find_with_break([1, 2], some_bool))

# `loop` is a call with a block, so its value IS the break arm: the
# callee's own result is uninhabited (the loop never falls through).
def loop_value
  loop do
    break 5
  end
end

assert_type("5", loop_value)

# The arm is typed in the scope that reaches it, not the block's entry
# scope: `v` is a String by the time the `break` runs.
def rebound_arm(flag)
  m = Mutex.new
  v = 1
  m.synchronize do
    v = "s"
    break v if flag

    42
  end
end

assert_type('"s" | 42', rebound_arm(some_bool))

# A `break` a nested block owns terminates THAT call, so it joins the
# inner `each` and never reaches the outer `synchronize`.
def nested_block_break
  m = Mutex.new
  m.synchronize do
    [1, 2].each { break 9 }
    42
  end
end

assert_type("42", nested_block_break)

# A loop consumes `break` as its own exit — same barrier rule.
def loop_break(flag)
  m = Mutex.new
  m.synchronize do
    while flag
      break 5
    end
    42
  end
end

assert_type("42", loop_break(some_bool))

# `break` and `next` at once: the `next` arm joins the BLOCK's value and
# the `break` arm the CALL's, and neither suppresses the other.
def both_arms(flag, other)
  m = Mutex.new
  m.synchronize do
    break "b" if flag
    next :n if other

    42
  end
end

assert_type('"b" | 42 | :n', both_arms(some_bool, some_bool))

# A multi-value `break a, b` terminates the call with the array `[a, b]`,
# matching `return a, b` and `next a, b`.
def multi_value_arm(xs, flag)
  xs.each do |_x|
    break 1, "x" if flag
  end
end

assert_type('Array | [1, "x"]', multi_value_arm([1, 2], some_bool))

# Flow sensitivity comes free from the evaluator's dead-arm skip: `x` is
# pinned per position, so `x.nil?` folds to false and the arm is never
# entered. A union that widened every guarded `break` unconditionally
# would answer `["1", "2"] | nil` here.
assert_type('["1", "2"]', [1, 2].map do |x|
  break nil if x.nil?

  x.to_s
end)
