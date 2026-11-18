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

# === A closure made before the loop captures the local and writes it:
# `[:sym, :sym]`. The local's continuation binding carries a `Dynamic[top]`
# arm for that write, which the binding at the store lacks, so the two are
# joined.
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

# === A store in a class or method body inside the loop is on that body's
# own locals: the loop's `own` and `mine` hold `["a", "a"]`, and the inner
# `5` reaches neither.
own = []
i = 0
while i < 2
  s = "a"
  class LoopStoreScope
    s = 5
    own = []
    own << s
  end
  own << s
  i += 1
end
assert_type("Array[Dynamic[top] | String]", own)

mine = []
i = 0
while i < 2
  s = "a"
  def loop_store_scope
    s = 5
    mine = []
    mine << s
  end
  mine << s
  i += 1
end
assert_type("Array[Dynamic[top] | String]", mine)
