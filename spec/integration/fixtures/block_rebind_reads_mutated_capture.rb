require "rigor/testing"
include Rigor::Testing

# ADR-56 slice A — a block that rebinds a captured local FROM a captured
# collection the same body mutates in place. The rebind fixpoint re-ran the
# body with only the rebound locals moving; the collection re-entered every
# pass at its pre-call contents, so the rebind read the first iteration's
# answer and the fixpoint closed over it. Every comparison below is TRUE at
# runtime unless it is marked. Each pass now reads the collection as if
# every mutation site had already stored an unknown value, so a rebind read
# from an Array or a Hash carries that store's gradual arm.

# --- The rebind reads the collection's tail before appending to it. ---
tail = [0]
last = nil
[1, 2].each do |x|
  last = tail.last
  tail << x
end
assert_type("0 | Dynamic[top] | nil", last)
puts "one" if last == 1

# --- The rebind reads a Hash slot the body then stores to. (The store
# computes from the collection, not from the rebind: a store that reads a
# rebound local is slice C's evidence, a separate residue.) ---
counts = { a: 0 }
seen = 0
%i[a a].each do |k|
  seen = counts[k]
  counts[k] += 1
end
assert_type("0 | Dynamic[top] | Integer", seen)
puts "one" if seen == 1

# --- The rebind reads the collection's emptiness. ---
buf = []
was_empty = true
[1, 2].each do |x|
  was_empty = buf.empty?
  buf << x
end
assert_type("bool", was_empty)
puts "filled" unless was_empty

# --- A String accumulator's size: a String mutator widens to `String`
# whatever it stored, so no gradual arm is needed. ---
text = +""
len = 0
%w[a b].each do |w|
  len = text.size
  text << w
end
assert_type("0 | non-negative-int", len)
puts "one" if len == 1

# --- A remover written before the adder: the rebind reads what the
# previous pass pushed. ---
stack = [0]
prev = nil
[1, 2].each do |x|
  prev = stack.pop
  stack.push(x)
end
assert_type("0 | Dynamic[top] | nil", prev)
puts "one" if prev == 1

# --- A slot rewriter: `replace` closed the Hash to `Hash[Symbol, Integer]`,
# so the String the body stores drew `undefined method 'upcase'`. ---
store = { a: 0 }
got = nil
%w[x y].each do |s|
  got = store[:k]
  store.replace({})
  store[:k] = s
end
puts got.upcase if got

# --- A pure remover: `delete` closed the Hash to `Hash[Symbol, 0]`, whose
# read of a missing key answered `0` with no room for its `nil`. ---
pruned = { a: 0 }
missing = 1
[1, 2].each do
  missing = pruned[:b]
  pruned.delete(:a)
end
puts "nil" if missing == nil

# --- A collection the body both rebinds and mutates: the rebind fixpoint's
# own running binding came from the straight-line seam, which closed
# `[0]` to `Array[0]` under the `pop`. ---
queue = [0]
head = nil
[1, 2].each do |x|
  queue ||= [0]
  head = queue.pop
  queue.push(x)
end
puts "one" if head == 1

# --- A collection already closed before the call: the straight-line
# `pop` left `Array[0 | 9]`, a value-pinned nominal the `push` in the body
# declines, so the rebind read the pins on every pass. ---
pinned = [0, 9]
pinned.pop
peeked = nil
[1, 2].each do |x|
  peeked = pinned.last
  pinned.push(x)
end
puts "one" if peeked == 1

# --- Paired control: the same rebind shape over a collection the body
# does NOT mutate. Only `out` moves, so `base` keeps its exact contents and
# the comparison it rules out still folds — `base.last` is only ever 0. ---
base = [0]
out = []
first = nil
[1, 2].each do |x|
  first = base.last
  out << x
end
assert_type("0?", first)
puts "one" if first == 1 # GENUINE-FALSEY

# --- Control: an inner block parameter that shares the outer name is a
# different variable. `tail2` is never mutated, so `peek` is only ever 0. ---
tail2 = [0]
peek = nil
[1, 2].each do |x|
  peek = tail2.last
  [[9]].each { |tail2| tail2 << x }
end
puts "one" if peek == 1 # GENUINE-FALSEY
