require "rigor/testing"
include Rigor::Testing

# ADR-56 slice C — a block store whose value reads a local the SAME body
# writes. The join typed each store's evidence in the block-entry scope,
# which binds such a local where the call found it: `out << total`
# stored the pre-call `0` on every iteration as far as the join could
# tell, `out` read `Array[0]`, and `out.last == 3` folded always-falsey
# on a program whose `out` is `[1, 3]`. Each such store now reads the
# local where it runs. Every comparison below is TRUE at runtime unless
# it is marked, and nothing but the marked line may report.

# --- Array: the appended value is a running total. ---
total = 0
out = []
[1, 2].each do |x|
  total += x
  out << total
end
assert_type("Array[Integer]", out)
puts "three" if out.last == 3

# --- Hash: the stored value is a running total. ---
run = 0
latest = { a: 0 }
[1, 2].each do |x|
  run += x
  latest[:a] = run
end
assert_type("Hash[:a | Symbol, 0 | Integer]", latest)
puts "three" if latest[:a] == 3

# --- `each_with_object`: the memo stores a running total. ---
sum = 0
memo = [1, 2].each_with_object([]) do |x, m|
  sum += x
  m << sum
end
assert_type("Array[Integer]", memo)
puts "three" if memo.last == 3

# --- The same memo on a receiver Rigor cannot prove non-escaping: the
# rebound local enters at the escaping-block floor. ---
def running(xs)
  count = 0
  r = xs.each_with_object([]) do |_x, m|
    count += 1
    m << count
  end
  puts "two" if r.last == 2
end
running([1, 2])

# --- A read between two rebinds sees the value written just before it.
# Slice A's continuation is `nil | :done`, under which `state.length`
# would answer `4`. ---
state = nil
lengths = []
%w[a bb].each do |s|
  state = s
  lengths << state.length
  state = :done
end
assert_type("Array[1 | 2]", lengths)
puts "two" if lengths.last == 2

# --- An exit value the store never reads stays out of the collection:
# the continuation holds the reset `nil`, the store does not. ---
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
assert_type("Array[1 | 3]", positives)
positives.each { |v| puts v + 1 }

# --- A flow guard at the store narrows the local it reads. ---
last = 0
kept = []
[1, nil, 3].each do |x|
  kept << last if last
  last = x
end
assert_type("Array[0 | 1 | 3]", kept)
kept.each { |v| puts v + 1 }

# --- A declared return type meets the stored value, not the `5` the
# body resets the local to afterwards. ---
class ReboundCaptureReturn
  #: () -> Array[String]
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

# --- A local computed from the collection the block fills reads that
# collection at its gradual floor, not at its pre-call contents. `size`
# itself still reads `0` (runtime `1`): slice A reads `sizes` at its
# pre-call contents, ADR-56 WD2.13's second residue. ---
sizes = []
size = 0
[1, 2].each do
  size = sizes.size
  sizes << size
end
puts "one" if sizes.last == 1

# --- A local that is nil until the collection it guards exists: the
# walk floors that collection member by member, so the `nil` survives
# and `pending ? :cont : :start` keeps both arms. ---
phase = :none
phases = []
pending = nil
[1, 2].each do |x|
  phase = pending ? :cont : :start
  phases << phase
  pending ||= []
  pending << x
end
assert_type("Array[:cont | :start]", phases)
puts "start" if phases.first == :start

# --- Shapes one more walk of the body cannot stand for keep the
# block-entry reading, which reads the untyped parameter here. ---

# A store inside a loop of its own: the walk sees the loop's capped
# passes, never its widened answer.
def counted(start)
  i = start
  counts = []
  [1].each do
    i = 0
    while i < 10
      i += 1
      counts << i
    end
  end
  puts "ten" if counts.last == 10
end
counted(0)

# A `break` beside an `else`: `eval_if` joins the breaking branch's
# `nil` into the scope after it.
def upcased(start)
  word = start
  words = []
  %w[a b c].each do |x|
    if x == "c"
      word = nil
      break
    else
      word = x.upcase
    end
    words << word
  end
  words.each { |w| puts w.downcase }
end
upcased("")

# A local written inside an argument, which no later scope carries (#1223).
def marked(start)
  mark = start
  marks = []
  seen = nil
  [1, 2].each do |x|
    mark = seen ? :later : :first
    marks << mark
    [seen = x].size
  end
  puts "later" if marks.last == :later
end
marked(nil)

# An instance variable the body writes: the walk enters with it where the
# call found it.
class ReboundCaptureIvar
  def run(start)
    @count = 0
    seen = start
    counts = []
    [1, 2].each do
      @count += 1
      seen = @count
      counts << seen
    end
    puts "two" if counts.last == 2
  end
end
ReboundCaptureIvar.new.run(nil)

# --- A block parameter reassigned before the store. ---
bumped = []
[1, 2].each do |n|
  n += 1
  bumped << n
end
assert_type("Array[2 | 3]", bumped)
puts "three" if bumped.last == 3

# --- A block parameter still shadows the outer local it names: the store
# reads the yielded element, never the outer "s", though the body writes
# the name. ---
shadow = "s"
got = []
[1, 2].each do |shadow|
  got << shadow
  shadow = nil
end
assert_type("Array[1 | 2]", got)
puts "two" if got.last == 2

# --- Residue: slice A drops the scope at `next` and keeps the dead reset
# after it, so a body that jumps to its next iteration keeps the
# block-entry reading rather than store a `nil` it never stores. Runtime
# `stepped` is `[0, 1, 2]`. Flip this when #1214 is fixed. ---
step = 0
stepped = []
[1, 2, 3].each do |x|
  stepped << step
  step = x
  next if x > 0

  step = nil
end
assert_type("Array[0]", stepped)
stepped.each { |v| puts v + 1 }

# --- Paired control: the store only ever reads `1`, so the evidence stays
# precise and the comparison it rules out still folds. ---
flag = 0
seen = []
[1, 2].each do
  flag = 1
  seen << flag
end
assert_type("Array[1]", seen)
puts "two" if seen.last == 2 # GENUINE-FALSEY
