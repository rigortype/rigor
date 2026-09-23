require "rigor/testing"
include Rigor::Testing

# Issue #1223 — a write nested in a call's receiver or arguments, in an
# array literal or an interpolation, or in a `rescue` modifier reaches the
# scope after the statement. The statement walk typed those positions as
# pure expressions, so each local below kept its pre-write binding and the
# comparison after it folded always-falsey on correct code. Every
# comparison is TRUE at runtime unless it is marked, and nothing but the
# marked lines may report.

step = Integer(ENV.fetch("STEP", "1"))

def record_values(*values, **options)
  [values, options]
end

# --- A compound write as a mutator's argument. ---
n = 0
out = []
out << (n += step)
puts "one" if n == 1

# --- The same write in a non-escaping block reaches ADR-56's write-back. ---
total = 0
kept = []
[1, 2].each { |x| kept << (total += x) }
puts "three" if total == 3

# --- A plain write as an argument, in a block. ---
last = :init
[1, 2].each { |e| puts(last = e) }
puts "two" if last == 2

# --- The receiver of a comparison. ---
seen = 0
stepped = (seen += step) == 1
puts "one" if seen == 1

# --- An index argument, a positional and a keyword argument. ---
slot = 0
table = { 1 => :a }
table[slot = step]
puts "one" if slot == 1

level = 0
tag = :off
record_values(level = step, label: (tag = step == 1 ? :on : :off))
puts "one" if level == 1
puts "on" if tag == :on

# --- An array literal and an interpolation. ---
count = 0
pair = [:x, count += step]
puts "one" if count == 1

lines = 0
puts "line #{lines += step}"
puts "one" if lines == 1

# --- A `rescue` modifier's rescue arm may run. ---
parsed = :none
Integer("x") rescue (parsed = :fallback)
puts "fallback" if parsed == :fallback

# --- An instance-variable assignment's right-hand side, and an instance
# variable written as an argument (to an explicit receiver: an implicit-self
# call would widen the ivar to its class-wide seed on its own). ---
class ArgumentWriteLabel
  def initialize(step)
    width = 0
    @label = format("%d", width = step)
    puts "one" if width == 1
    @memo = nil
    $stdout.puts(@memo ||= step)
    $stdout.puts "one" if @memo == 1
  end
end
ArgumentWriteLabel.new(step)

# --- A block-level `next` / `break` inside an argument leaves with the
# write before it. ---
tail = :init
[2, 1].each do |e|
  puts((tail = e).odd? && next)
  tail = :fell
end
puts "one" if tail == 1

hit = nil
[1, 2].each do |e|
  puts((hit = e).even? && break)
  hit = :missed
end
puts "two" if hit == 2

# --- The call's own block runs after its arguments: it reads the
# argument's write, and a rebind in it joins with that write rather than
# with the binding before the call. ---
bound = nil
seen_bound = nil
1.upto(bound = step) { |_i| seen_bound = bound }
puts "one" if seen_bound == 1

stop = nil
1.upto(stop = step - 1) { |_i| stop = :ran }
puts "zero" if stop == 0

1.upto(fresh = step) { |_i| fresh = :ran }
puts "ran" if fresh == :ran

# --- A write in an `&&` predicate's right operand certainly ran on the
# truthy edge, so the body reads it without the `nil` of the path that
# skipped it — nested in a comparison's argument, or as a statement. ---
def arg_write_width(_items)
  Integer(ENV.fetch("WIDTH", "2"))
end

def arg_write_guard(items)
  if !items.empty? && items.size >= (width = arg_write_width(items))
    puts width + 1
  end
  if !items.empty? && (count = arg_write_width(items); items.size >= count)
    puts count + 1
  end
end
arg_write_guard(%w[a b])

# --- The same edge keeps what the left operand narrowed although the
# right operand's call resets instance variables and regex globals, as
# the edge read off the joined scope always did. ---
class ArgumentWriteTree
  def initialize(parent)
    @parent = parent ? "root" : nil
  end

  def find_node
    ENV.fetch("NODE", "leaf")
  end

  def guarded
    return unless @parent && (node = find_node)

    parent = @parent
    "#{parent.upcase}/#{node}"
  end
end
ArgumentWriteTree.new(true).guarded

def arg_write_parse(line)
  if line =~ /\A(\w+)=(\d+)\z/ && (key = Integer($2))
    name = $1
    puts name.upcase, key
  end
end
arg_write_parse("a=1")

# --- A call nested in an operand applies no statement-position reset:
# `$1` stays narrowed after `Integer(value = $2)` as after `Integer($2)`. ---
def arg_write_capture(line)
  return unless line =~ /\A(\w+)=(\d+)\z/

  $stdout.puts(Integer(value = $2))
  name = $1
  puts name.upcase, value
end
arg_write_capture("a=1")

# --- A mutator on a parenthesised write mutates the variable it writes,
# and the element an index `||=` stores. ---
buf = nil
(buf ||= []) << 1
puts "one" if buf.size == 1

groups = {}
(groups[:a] ||= []) << 1
puts "one" if groups[:a].size == 1

tallies = {}
tallies[:a] ||= []
tallies[:a] << 1
puts "one" if tallies[:a].size == 1

# --- A provably-live branch runs on the edge the right operand ran on. ---
text = ENV.fetch("TEXT", "t")
if text && (text_width = text.size)
  puts text_width + 1
end

# --- Paired controls: an argument that writes nothing leaves its local
# alone, and a write storing a value the comparison rules out still
# folds. ---
unchanged = 0
puts(unchanged + 1)
puts "one" if unchanged == 1 # GENUINE-FALSEY

switched = step == 1 ? :a : :b
puts(switched = :c)
puts "a" if switched == :a # GENUINE-FALSEY

picked = step == 1 ? :a : :b
record_values(0, label: (picked = :c))
puts "a" if picked == :a # GENUINE-FALSEY
