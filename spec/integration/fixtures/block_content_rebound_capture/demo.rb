require "rigor/testing"
include Rigor::Testing

# ADR-56 slice C — a block store whose value reads a local the SAME body
# writes. The join typed each store's evidence in the block-entry scope,
# which binds such a local where the call found it: `out << total`
# stored the pre-call `0` on every iteration as far as the join could
# tell, `out` read `Array[0]`, and `out.last == 3` folded always-falsey
# on a program whose `out` is `[1, 3]`. Such a store now reads the local
# as `Dynamic[top]`. Every comparison below is TRUE at runtime unless it
# is marked, and nothing but the marked lines may report.

# --- Array: the appended value is a running total. ---
total = 0
out = []
[1, 2].each do |x|
  total += x
  out << total
end
assert_type("Array[Dynamic[top]]", out)
puts "three" if out.last == 3

# --- Hash: the stored value is a running total. ---
run = 0
latest = { a: 0 }
[1, 2].each do |x|
  run += x
  latest[:a] = run
end
puts "three" if latest[:a] == 3

# --- `each_with_object`: the memo stores a running total. ---
sum = 0
memo = [1, 2].each_with_object([]) do |x, m|
  sum += x
  m << sum
end
assert_type("Array[Dynamic[top]]", memo)
puts "three" if memo.last == 3

# --- The write is the store's own argument. `count` itself reads
# `Integer` since #1223; the store still reads it as `Dynamic[top]`. ---
count = 0
ids = []
%w[a b c].each { |_s| ids << (count += 1) }
puts "three" if ids.last == 3

# --- A read between two rebinds: slice A's continuation is `nil | :done`,
# under which `state.length` would answer `4`. ---
state = nil
lengths = []
%w[a bb].each do |s|
  state = s
  lengths << state.length
  state = :done
end
puts "two" if lengths.last == 2

# --- An exit value no store reads: the continuation holds the reset
# `nil`, which would report on `v + 1`. ---
prev = 0
positives = []
[1, -2, 3].each do |x|
  if x > 0
    prev = x
    positives << prev
  else
    prev = nil
  end
end
positives.each { |v| puts v + 1 }

# --- A declared return type (`sig/rebound_capture.rbs`) meets the store,
# not the `5` the body resets the local to afterwards. ---
class ReboundCaptureReturn
  def successors
    state = nil
    out = []
    %w[a bb].each do |s|
      state = s
      out << state.succ
      state = 5
    end
    out
  end
end
ReboundCaptureReturn.new.successors

# --- A block parameter reassigned before the store. ---
bumped = []
[1, 2].each do |n|
  n += 1
  bumped << n
end
puts "three" if bumped.last == 3

# --- An `inject` accumulator is not fresh on every iteration.
# `acc_total` itself still reads `0 | 1 | 2` (runtime `3`); flip the
# golden when #1232 is fixed. ---
acc_total = 0
sums = []
[1, 2].inject(0) do |acc, x|
  acc_total = acc + x
  sums << acc_total
  acc_total
end
puts "three" if sums.last == 3

# --- A value carried into the next iteration only through `next`. ---
step = 0
stepped = []
[1, 2, 3].each do |x|
  stepped << step
  step = x
  next if x > 0

  step = nil
end
puts "two" if stepped.last == 2

# --- A store inside an inner block reads the outer rebound local too. ---
outer = 0
nested = []
[1, 2].each do |x|
  outer += x
  [x].each { |_y| nested << outer }
end
puts "three" if nested.last == 3

# --- A collection the body both rebinds and grows: the join's seed
# carries slice A's continuation, which misses the `[:m]` read between
# two rebinds. ---
tags = [:a]
firsts = []
[1, 2].each do |_x|
  tags = [:m]
  firsts << tags.first
  tags << :b
  tags = [:c]
end
puts "m" if firsts.last == :m

# --- An index the body increments stays out of the reading: typed as
# `Dynamic[top]` it would make the join take `[x, x]` for a splice as
# well, and `x` itself would reach the declared `Array[Array[Integer]]`
# (`sig/rebound_capture.rbs`). ---
class ReboundCaptureGrid
  def rows
    grid = []
    i = 0
    [1, 2].each do |x|
      grid[i] = [x, x]
      i += 1
    end
    grid
  end
end
ReboundCaptureGrid.new.rows

# --- A Hash key the body rebinds is covered, unlike an Array index: the
# key reads `:a` at block entry, and `by_key.keys.last == :b` would fold. ---
by_key = {}
key = :a
[1, 2].each do |x|
  by_key[key] = x
  key = :b
end
puts "b" if by_key.keys.last == :b

# --- A parameter's default that rebinds an outer local counts as a write.
# Slice A does not see that write, so `defaulted` itself would pin `0`;
# the method keeps it out of the golden's locals. ---
def defaulted_totals
  defaulted = 0
  defaults = []
  [1, 2].each do |x, _y = (defaulted += x)|
    defaults << defaulted
  end
  puts "three" if defaults.last == 3
end
defaulted_totals

# --- The value an index store writes keeps its precise type when it
# reads nothing the body writes. ---
names = []
slot = 0
%w[a b].each do |w|
  names[slot] = w.upcase
  slot += 1
end
assert_type("Array[\"A\" | \"B\"]", names)

# --- Paired controls: a store reading a local the body does not write,
# or a parameter it does not reassign, keeps its precise binding beside a
# rebind, and the comparisons it rules out still fold. ---
limit = 5
tally = 0
caps = []
[1, 2].each do |x|
  tally += x
  caps << limit
end
assert_type("Array[5]", caps)
puts "six" if caps.last == 6 # GENUINE-FALSEY

picked = []
[1, 2].each do |n|
  tally += n
  picked << n
end
assert_type("Array[1 | 2]", picked)
puts "three" if picked.last == 3 # GENUINE-FALSEY

# An inner block's own parameter of the same name is a different variable:
# the body does not write `width`.
width = 5
widths = []
[1, 2].each do |_y|
  widths << width
  [3].each { |width| width += 1 }
end
assert_type("Array[5]", widths)
puts "six" if widths.last == 6 # GENUINE-FALSEY

# A method body the block defines is a scope of its own: the body does
# not write `limit_seen`.
limit_seen = 5
limits = []
[1, 2].each do
  limits << limit_seen
  def self.reset_limit
    limit_seen = 1
    limit_seen
  end
end
assert_type("Array[5]", limits)
puts "six" if limits.last == 6 # GENUINE-FALSEY
