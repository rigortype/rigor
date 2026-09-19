require "rigor/testing"
include Rigor::Testing

# Issue #1094 — destructuring a union right-hand side distributes over its
# members, and a value without an implicit `to_ary` binds as Ruby's `[rhs]`.

# A union of tuples joins per name.
def tuple_union = rand > 0.5 ? [1, "s", :t] : [1.0]
e, *f = tuple_union
assert_type("1 | 1.0", e)
assert_type("[\"s\", :t] | []", f)

# `Array[T] | nil` (a slice): the nil member wraps to `[nil]` and the Array
# member binds `T`; the member's bare `nil` is softened out of the join (and
# the slot marked optimistic), exactly as a short array's padding is.
def slice_of(words) = words.map(&:size)[1..]
g, h = slice_of(ARGV)
assert_type("non-negative-int", g)
assert_type("non-negative-int", h)

# Which member arrived is correlated across the slots, so the guarded read
# of the second slot must not see `nil` (no `call.possible-nil-receiver`).
def first_long = ARGV.group_by(&:size).find { |size, _| size > 2 }
def guarded
  size, group = first_long
  assert_type("Array[String]", group)
  group.first if size
end

def status_of(flag) = flag ? [:ok, "value"] : [:err]
def status_read(flag)
  status, value = status_of(flag)
  assert_type(":err | :ok", status)
  value.upcase if status == :ok
end

# Scalars without `to_ary` wrap: the first slot is the value, the other
# fixed slots `nil`, the rest `[]`.
a, b = 1
assert_type("1", a)
assert_type("nil", b)
c, d = { k: 1 }
assert_type("{ k: 1 }", c)
assert_type("nil", d)
x, *y, z = nil
assert_type("nil", x)
assert_type("[]", y)
assert_type("nil", z)

# A class the project reopens with `to_ary` may convert, so it stays
# Dynamic; an untouched RBS class with no conversion wraps.
class Time
  def to_ary = [self]
end
# (Inside a method body: the snapshot's top-level locals come from a pass that
# does not see the project's class declarations.)
def reopened_time
  t1, t2 = Time.now
  assert_type("Dynamic[top]", t1)
  assert_type("Dynamic[top]", t2)
  r1, r2 = (1..2)
  assert_type("1..2", r1)
  assert_type("nil", r2)
end

# A Ruby-source class answering `respond_to_missing?` — an open hierarchy the
# RBS environment does not know — stays Dynamic.
class Proxy
  def method_missing(name, *args) = super
  def respond_to_missing?(name, include_private = false) = name == :to_ary || super
end
def proxied
  p1, p2 = Proxy.new
  assert_type("Dynamic[top]", p1)
  assert_type("Dynamic[top]", p2)
end
