require "rigor/testing"
include Rigor::Testing

# Issue #1412 — a repeating block or loop body that mutates a captured
# local in place (`<<`, `push`, `[]=`) and never rebinds it was typed from
# the local's pre-body contents on every pass. Only the ADR-56 write-back
# laid the WD2.13 unknown-store widening, and it runs only for a body that
# also rebinds a capture, so `depth = []` read `[]` on every iteration:
# `depth.last` was `nil`, and the guarded `depth.last.length` reported
# `undefined method 'length' for nil` at error level on correct code. At
# runtime only the first pass skips the branch. Every read below is live
# unless it is marked.

# --- The issue's repro, on an untyped receiver. ---
def lists_each(lines)
  depth = []
  lines.each do |tl|
    puts depth.last.length if depth.last
    depth << tl
  end
end

# --- The same with a catalogued iterator's second parameter. ---
def lists_each_with_index(lines)
  depth = []
  lines.each_with_index do |tl, _i|
    puts depth.last.length if depth.last
    depth << tl
  end
end

# --- `push` instead of `<<`. ---
def lists_push(lines)
  depth = []
  lines.each do |tl|
    puts depth.last.length if depth.last
    depth.push(tl)
  end
end

# --- An index write. ---
def lists_index_write(lines)
  depth = []
  lines.each do |tl|
    puts depth.last.length if depth.last
    depth[depth.size] = tl
  end
end

# --- A Hash slot store. ---
def hash_store(lines)
  seen = {}
  lines.each do |tl|
    puts seen[:a].length if seen[:a]
    seen[:a] = tl.to_s
  end
end

# --- A typed receiver, whose body appends and rebinds nothing. ---
def typed_receiver
  lines = Array.new(3) { "x" }
  depth = []
  lines.each do |tl|
    assert_type("Array[Dynamic[top]]", depth)
    puts depth.last.length if depth.last
    depth << tl
  end
end

# --- A `while` loop, whose body also rebinds a counter. ---
def lists_while(lines)
  depth = []
  i = 0
  while i < lines.size
    puts depth.last.length if depth.last
    depth << lines[i]
    i += 1
  end
end

# --- An `until` loop, whose body rebinds nothing. ---
def lists_until(lines)
  depth = []
  until lines.empty?
    puts depth.last.length if depth.last
    depth << lines.shift
  end
end

# --- A `for` loop, whose body runs again as a `while` body does. ---
def lists_for(lines)
  depth = []
  for tl in lines
    puts depth.last.length if depth.last
    depth << tl
  end
end

# --- The state machine redmine's CVS log reader runs: the slot write is
# reached only after an earlier line rebound the `nil` placeholder to a
# Hash. The escape analysis leaves the call `:unknown`, so no ADR-56
# write-back runs; the placeholder enters joined with `Dynamic[top]`. ---
def state_machine(io)
  state = :start
  names = nil
  io.each_line do |line|
    if state == :start
      names = {}
      state = :names
    else
      names[line] = true
    end
  end
end

# --- A Hash the body rebinds per record and stores every field into, as
# redmine's git log reader does: it enters at its unknown-store widening. ---
def commit_reader(io)
  changeset = {}
  state = 0
  io.each_line do |line|
    if line =~ /^commit (\w+)( \w+)?$/
      parents_str = $2
      if state == 1
        state = 0
        puts ENV.fetch(changeset[:date])
        changeset = {}
      end
      changeset[:commit] = $1
      changeset[:parents] = parents_str.strip.split(" ") unless parents_str.nil?
    elsif line =~ /^(\w+):\s*(.*)$/
      changeset[:date] = $2
      state = 1
    end
  end
end

# --- A local that is not a `nil` / `false` placeholder keeps its call-site
# binding on an unproven call, so each read below — which only a later
# pass makes, behind a guard the seed decides — stays unreported. ---
def rebinds_to_another_class(items)
  n = 0
  items.each { |i| puts n.upcase unless n == 0; n = i.to_s }
end

def rebinds_behind_a_class_guard(items)
  last = 0
  items.each { |i| puts last.abs if last.is_a?(Integer); last = i.to_s }
end

def rebind_gated_by_a_flag(lines)
  first = true
  last = 0
  lines.each do |line|
    puts last.strip unless last == 0
    if first then first = false else last = "#{line}" end
  end
end

def rebind_gated_by_a_state(lines)
  state = :header
  last = 0
  lines.each do |line|
    puts last.strip unless last == 0
    case state
    when :header then state = :body
    when :body then last = "#{line}"
    end
  end
end

def rebind_gated_by_a_counter(lines)
  n = 0
  last = 0
  lines.each do |line|
    puts last.strip unless last == 0
    last = "#{line}" if n > 0
    n += 1
  end
end

def self_dependent_rebind(items)
  x = 0
  items.each do |_i|
    puts x.bytesize unless x == 0 || x == 1
    x = (x == 0 ? 1 : "s")
  end
end

# --- Control: the same call-site binding keeps a read that fails on every
# pass reported. ---
def counter_read_before_rebind(items)
  count = 0
  items.each do
    count.upcase # STILL-REPORTED
    count += 1
  end
end

def name_read_before_rebind(items)
  name = "x"
  items.each do |i|
    name.no_such_method # STILL-REPORTED
    name = i.to_s
  end
end

# --- Control: an implicit-self iterator in an `Enumerable` class. ---
class Tree
  include Enumerable

  def each
    yield 1
    yield 2
  end

  def prev_read_before_rebind
    prev = 0
    each_with_index do |x, _i|
      prev.upcase # STILL-REPORTED
      prev = x
    end
  end
end

# --- Control: a known receiver takes the write-back, whose entry keeps the
# `nil` the first pass reads. ---
def known_receiver_first_pass
  items = [1, 2, 3]
  x = nil
  items.each do |i|
    x.length # STILL-REPORTED
    x = i.to_s
  end
end

# --- Control: a project `each` that yields once is not read as repeating
# (issue #1234). ---
class Once
  def each
    yield 1
  end
end

def project_each_once
  x = nil
  Once.new.each do |i|
    x.foo # STILL-REPORTED
    x = i
  end
end

# --- Control: a body that never mutates the collection. `depth.last` is a
# call, so the guard does not narrow it, and the read is still reported. ---
def never_appends(lines)
  depth = []
  lines.each do |_tl|
    puts depth.last.length if depth.last # STILL-REPORTED
  end
end

# --- Control: `then` runs its block exactly once, so the entry binding is
# exact and the mutation reaches no later pass. ---
def runs_once
  depth = []
  5.then do |n|
    puts depth.last.length if depth.last # STILL-REPORTED
    depth << n
  end
end

# --- Control: an uncatalogued block call on a known receiver is not read
# as repeating. ---
def uncatalogued_call
  depth = []
  Mutex.new.synchronize do
    puts depth.last.length if depth.last # STILL-REPORTED
    depth << 1
  end
end
