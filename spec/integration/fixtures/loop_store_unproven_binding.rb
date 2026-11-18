require "rigor/testing"
include Rigor::Testing

# Issue #3337, review round 1 — where the loop seam must NOT replace a
# local's continuation binding with its binding at the store. Each section
# says what Ruby 4.0.5 leaves in the collection; every answer here is the
# one the seam gave before it read a store's arguments where the store
# runs, and holds every class Ruby stores.

# === A local the store does not follow an assignment of. `c` is assigned
# on the first iteration only, and a guard narrows its `nil` away at the
# store, but the store may hold what an EARLIER iteration left: `5`. Ruby
# leaves `["x", "x", 5]` in each of these unless the section says otherwise.

guarded = []
i = 0
while i < 3
  c = "x" if i.zero?
  guarded << c if c
  c = 5 if i.odd?
  i += 1
end
assert_type("Array[Integer | String | nil]", guarded)

unless_nil = []
i = 0
while i < 3
  c = "x" if i.zero?
  unless_nil << c unless c.nil?
  c = 5 if i.odd?
  i += 1
end
assert_type("Array[Integer | String | nil]", unless_nil)

matched = []
i = 0
while i < 3
  c = "x" if i.zero?
  case c
  in nil then nil
  else matched << c
  end
  c = 5 if i.odd?
  i += 1
end
assert_type("Array[Integer | String | nil]", matched)

# a `begin … end while` body
post_test = []
i = 0
begin
  c = "x" if i.zero?
  post_test << c if c
  c = 5 if i.odd?
  i += 1
end while i < 3
assert_type("Array[Integer | String | nil]", post_test)

# `until`
negated = []
i = 0
until i >= 3
  c = "x" if i.zero?
  negated << c if c
  c = 5 if i.odd?
  i += 1
end
assert_type("Array[Integer | String | nil]", negated)

# `[5, "x", "x"]`
front = []
i = 0
while i < 3
  c = "x" if i.zero?
  front.unshift(c) if c
  c = 5 if i.odd?
  i += 1
end
assert_type("Array[Integer | String | nil]", front)

# `["x", "x", "x", "x", 5, 5]`
twice = []
i = 0
while i < 3
  c = "x" if i.zero?
  twice.push(c, c) if c
  c = 5 if i.odd?
  i += 1
end
assert_type("Array[Integer | String | nil]", twice)

slotted = []
i = 0
while i < 3
  c = "x" if i.zero?
  slotted[i] = c if c
  c = 5 if i.odd?
  i += 1
end
assert_type("Array[Integer | String | nil]", slotted)

# `{"x" => 1, 5 => 2}`
keys = {}
i = 0
while i < 3
  c = "x" if i.zero?
  keys.store(c, i) if c
  c = 5 if i.odd?
  i += 1
end
assert_type("Hash[Integer | String | nil, Integer]", keys)

# `{"x" => 0, 5 => 2}`
defaults = {}
i = 0
while i < 3
  c = "x" if i.zero?
  (defaults[c] ||= i) if c
  c = 5 if i.odd?
  i += 1
end
assert_type("Hash[Integer | String | nil, Dynamic[top]]", defaults)

# the store in an inner loop
inner = []
i = 0
while i < 3
  c = "x" if i.zero?
  j = 0
  while j < 1
    inner << c if c
    j += 1
  end
  c = 5 if i.odd?
  i += 1
end
assert_type("Array[Integer | String | nil]", inner)

# a multiple assignment is not an assignment the store is known to follow
multi = []
i = 0
while i < 3
  c, d = "x", 1 if i.zero?
  multi << c if c
  c = 5 if i.odd?
  i += 1
end
assert_type("Array[Integer | String | nil]", multi)

# `c ||= "x"` keeps what an earlier iteration left: `["x", 5, 5]`
kept = []
i = 0
while i < 3
  c ||= "x"
  kept << c
  c = 5
  i += 1
end
assert_type("Array[Integer | String | nil]", kept)

# === A store in a body that runs later. The proc is made on the first
# iteration and called after `s = 9`: Ruby leaves `[9, 9]`.
by_proc = []
i = 0
while i < 2
  s = "a"
  saved = proc { by_proc << s } if i.zero?
  s = 9
  saved.call
  i += 1
end
assert_type("Array[Integer?]", by_proc)

by_lambda = []
i = 0
while i < 2
  s = "a"
  saved = lambda { by_lambda << s } if i.zero?
  s = 9
  saved.call
  i += 1
end
assert_type("Array[Integer?]", by_lambda)

by_arrow = []
i = 0
while i < 2
  s = "a"
  saved = -> { by_arrow << s } if i.zero?
  s = 9
  saved.call
  i += 1
end
assert_type("Array[Integer?]", by_arrow)

by_new = []
i = 0
while i < 2
  s = "a"
  saved = Proc.new { by_new << s } if i.zero?
  s = 9
  saved.call
  i += 1
end
assert_type("Array[Integer?]", by_new)

# === A store in a block or a `for` body, which may run again after the
# body rebound the local: `["a", 5, "a", 5]`.
in_each = []
i = 0
while i < 2
  s = "a"
  [1, 2].each { in_each << s; s = 5 }
  i += 1
end
assert_type("Array[Integer | String | nil]", in_each)

in_for = []
i = 0
while i < 2
  s = "a"
  for x in [1, 2]
    in_for << s
    s = 5
  end
  i += 1
end
assert_type("Array[Integer | String | nil]", in_for)

# === A store in a rescue or `ensure` clause, which runs from any point of
# the body it guards: `["s", "s", :t]`. The spec beside this fixture
# checks that the check path and the display path agree on these.
cleanup = []
i = 0
while i < 2
  n = 1
  begin
    n = "s"
    Integer("z") if i.zero?
    n = :t
  rescue ArgumentError
    cleanup << n
  ensure
    cleanup << n
  end
  i += 1
end
assert_type("Array[Dynamic[top] | Symbol | nil]", cleanup)

# `[:t, :t]`
ensured = []
i = 0
while i < 2
  n = 1
  begin
    n = "s"
    n = :t
  ensure
    ensured << n
  end
  i += 1
end
assert_type("Array[Dynamic[top] | Symbol | nil]", ensured)

# === A store in the body a rescue clause guards, which `retry` runs again
# after the body's own later statements: `[1, :t, 1]`. The binding at the
# store is joined with the continuation binding, never taken alone.
retried = []
i = 0
while i < 2
  n = 1
  begin
    retried << n
    n = :t
    raise "again" if retried.size == 1
  rescue RuntimeError
    retry
  end
  i += 1
end
assert_type("Array[Dynamic[top] | Integer | Symbol | nil]", retried)

# === A block or lambda that writes the local, anywhere in the frame. The
# walk does not model that write at the call, so no assignment of such a
# local is one the store is known to follow.

# made before the loop, writing a Symbol: `[:sym, :sym]`
via_arrow = []
i = 0
s = nil
f = -> { s = :sym }
while i < 2
  s = "a"
  f.call
  via_arrow << s
  i += 1
end
assert_type("Array[Dynamic[top] | String]", via_arrow)

via_proc = []
i = 0
s = nil
f = proc { s = :sym }
while i < 2
  s = "a"
  f.call
  via_proc << s
  i += 1
end
assert_type("Array[Dynamic[top] | String]", via_proc)

via_lambda = []
i = 0
s = nil
f = lambda { s = :sym }
while i < 2
  s = "a"
  f.call
  via_lambda << s
  i += 1
end
assert_type("Array[Dynamic[top] | String]", via_lambda)

via_method = []
i = 0
s = nil
obj = Object.new
obj.define_singleton_method(:write) { s = :sym }
while i < 2
  s = "a"
  obj.write
  via_method << s
  i += 1
end
assert_type("Array[Dynamic[top] | String]", via_method)

# made in the loop body ahead of the assignment, writing `nil`: `[nil, nil]`
cleared_proc = []
i = 0
s = nil
while i < 2
  w = proc { s = nil }
  s = "a"
  w.call
  cleared_proc << s
  i += 1
end
assert_type("Array[String?]", cleared_proc)

cleared_arrow = []
i = 0
s = nil
while i < 2
  w = -> { s = nil }
  s = "a"
  w.call
  cleared_arrow << s
  i += 1
end
assert_type("Array[String?]", cleared_arrow)

cleared_lambda = []
i = 0
s = nil
while i < 2
  w = lambda { s = nil }
  s = "a"
  w.call
  cleared_lambda << s
  i += 1
end
assert_type("Array[String?]", cleared_lambda)

cleared_new = []
i = 0
s = nil
while i < 2
  w = Proc.new { s = nil }
  s = "a"
  w.call
  cleared_new << s
  i += 1
end
assert_type("Array[String?]", cleared_new)

cleared_singleton = []
i = 0
s = nil
target = Object.new
while i < 2
  target.define_singleton_method(:clear) { s = nil }
  s = "a"
  target.clear
  cleared_singleton << s
  i += 1
end
assert_type("Array[String?]", cleared_singleton)

cleared_method = []
i = 0
s = nil
holder = Class.new
while i < 2
  holder.send(:define_method, :clear) { s = nil }
  s = "a"
  holder.new.clear
  cleared_method << s
  i += 1
end
assert_type("Array[String?]", cleared_method)

# writing another class: `[7, 7]`
renumbered = []
i = 0
s = 1
while i < 2
  w = proc { s = 7 }
  s = "a"
  w.call
  renumbered << s
  i += 1
end
assert_type("Array[Integer | String]", renumbered)

# the other write forms; none changes what is stored here except the last
# two, which store `nil`: `["a", "a"]`, `["ab", "ab"]`, `[nil, nil]` twice
or_written = []
i = 0
s1 = nil
while i < 2
  w = proc { s1 ||= 3 }
  s1 = "a"
  w.call
  or_written << s1
  i += 1
end
assert_type("Array[String?]", or_written)

appended = []
i = 0
s2 = nil
while i < 2
  w = proc { s2 += "b" }
  s2 = "a"
  w.call
  appended << s2
  i += 1
end
assert_type("Array[String?]", appended)

and_written = []
i = 0
s3 = nil
while i < 2
  w = proc { s3 &&= nil }
  s3 = "a"
  w.call
  and_written << s3
  i += 1
end
assert_type("Array[String?]", and_written)

spread = []
i = 0
s4 = nil
while i < 2
  w = proc { s4, t = nil, 4 }
  s4 = "a"
  w.call
  spread << s4
  i += 1
end
assert_type("Array[String?]", spread)

# a closure in a parameter default writes the parameter: `[nil, nil]`, which
# the untyped parameter's `Dynamic[top]` arm stands for
def loop_store_default_closure(held = nil, clear = proc { held = nil })
  cleared = []
  i = 0
  while i < 2
    held = "a"
    clear.call
    cleared << held
    i += 1
  end
  assert_type("Array[Dynamic[top] | String]", cleared)
  cleared
end

# === A store in a class or method body inside the loop is on that body's
# own locals: the loop's `own` and `mine` hold `["a", "a"]`, and the inner
# `5` reaches neither. The `nil` is the join's own reading of the inner store.
own = []
i = 0
while i < 2
  u = "a"
  class LoopStoreScope
    u = 5
    own = []
    own << u
  end
  own << u
  i += 1
end
assert_type("Array[Dynamic[top] | String | nil]", own)

mine = []
i = 0
while i < 2
  u = "a"
  def loop_store_scope
    u = 5
    mine = []
    mine << u
  end
  mine << u
  i += 1
end
assert_type("Array[Dynamic[top] | String | nil]", mine)
