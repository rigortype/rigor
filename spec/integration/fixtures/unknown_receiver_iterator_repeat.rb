require "rigor/testing"
include Rigor::Testing

# Issue #1234 — a block whose call runs it more than once must be typed
# from the binding a later run reads, not the first run's. The captured-
# binding pass asked ClosureEscapeAnalyzer, which keys on the receiver's
# class, so a `Dynamic` receiver or a project class outside the catalogue
# answered `:unknown` and kept the first iteration's pinned values: a
# counter rebound inside the block read `0`, the predicate folded, and
# the condition on the call's value was reported as constant. Every
# condition below is decided at runtime unless it is marked.

# A project collection: `find` comes from `Enumerable`, reached through
# the class's own `include`, and runs the block once per element `each`
# yields.
class Shelf
  include Enumerable

  def initialize(items)
    @items = items
  end

  def each(&)
    @items.each(&)
  end
end

# --- `all?` on a `Dynamic` receiver: the second element sees `seen == 2`,
# so the result can be false. ---
def all_on_dynamic(items)
  seen = 0
  r = items.all? do |_x|
    seen += 1
    seen == 1
  end
  puts "one" if r
end

# --- `find` on a `Dynamic` receiver: the second run answers true. ---
def find_on_dynamic(items)
  seen = 0
  r = items.find do |_x|
    seen += 1
    seen == 2
  end
  puts r if r
end

# --- `find` on a project class that includes `Enumerable`. ---
def find_on_project_enumerable
  seen = 0
  r = Shelf.new([1, 2, 3]).find do |_x|
    seen += 1
    seen == 2
  end
  puts r if r
end

# --- Control: `then` runs its block exactly once, so the entry binding is
# exact — `first` is true on the only run and the nil arm is dead. ---
def then_runs_once
  first = true
  v = 5.then do |n|
    was = first
    first = false
    was ? n : nil
  end
  assert_type("Integer", v)
end

# --- Control: a block that rebinds nothing still folds. The predicate is
# false on every run, so `find` answers nil. ---
def find_never_matches(items)
  r = items.find { |_x| false }
  puts r if r # GENUINE-FALSEY
end
