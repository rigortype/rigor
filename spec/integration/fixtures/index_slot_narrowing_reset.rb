require "rigor/testing"
include Rigor::Testing

# Issue #1218 — `h[k] ||= default` records a narrowing on the `(h, k)` slot, and a later store into the slot must
# replace or drop it. A compound `h[k] += v` / `h[k] &&= v` only widened `h`, and the widening carries the slot
# narrowings across its rebind, so the slot kept reading the `||=` default (`h[:e] == 0` folded to always truthy
# after `h[:e] += 1`). A store whose index is not one literal key — `h[k] = v` with a variable `k`, a splice
# `s[0, 1] = …` — dropped nothing, though it may overwrite any slot. Each read below is the value Ruby holds there.
# Nothing in this file reports.

def operator_write_replaces_the_default
  h = { e: nil }
  h[:e] ||= 0
  h[:e] += 1
  assert_type("1", h[:e])
end

def and_write_replaces_the_default
  g = { e: nil }
  g[:e] ||= 0
  g[:e] &&= 5
  assert_type("5", g[:e])
end

def and_write_to_nil
  h = {}
  h[:k] ||= "a"
  h[:k] &&= nil
  assert_type("nil", h[:k])
end

def array_slot
  a = [nil]
  a[0] ||= 0
  a[0] += 1
  assert_type("1", a[0])
end

def other_literal_key_keeps_the_narrowing
  h = {}
  h[:k] ||= 0
  h[:j] += 1
  assert_type("0", h[:k])
end

def other_literal_plain_write_keeps_the_narrowing
  h = {}
  h[:k] ||= 0
  h[:j] = 1
  assert_type("0", h[:k])
end

def same_literal_plain_write
  h = {}
  h[:k] ||= 0
  h[:k] = 5
  assert_type("Dynamic[top] | Integer", h[:k])
end

def variable_key_operator_write(key)
  n = { e: nil }
  n[:e] ||= 0
  n[key] += 1
  assert_type("Dynamic[top]?", n[:e])
end

def variable_key_or_write(key)
  n = { e: nil }
  n[:e] ||= 0
  n[:e] &&= nil
  n[key] ||= 2
  assert_type("Dynamic[top]?", n[:e])
end

def variable_key_plain_write
  n = { e: nil }
  n[:e] ||= 0
  k = :e
  n[k] = 1
  assert_type("Dynamic[top]?", n[:e])
end

def splice_plain_write
  s = [1, 2, nil]
  s[2] ||= 5
  s[0, 1] = [1, 2]
  assert_type("Dynamic[top] | Integer | nil", s[2])
end

class IvarSlot
  def operator_write
    @h = {}
    @h[:k] ||= 0
    @h[:k] += 1
    assert_type("1", @h[:k])
  end
end

# A slot with no narrowing gets none: the store widens the receiver and the read answers from it.
def no_prior_narrowing
  h = { a: 1 }
  h[:a] += 1
  assert_type("Dynamic[top] | Integer", h[:a])
end

# A `String`'s `[]=` splices: `s[0] = "xy"` leaves `s[0] == "x"`. Nothing is recorded on it, by `||=` either.
def string_receiver
  s = +""
  s[0] ||= "x"
  s[0] += "y"
  assert_type("String?", s[0])
  t = +""
  t[0] ||= "xy"
  assert_type("String?", t[0])
end

class ClampedTable
  def initialize = @d = {}
  def [](key) = @d[key]

  def []=(key, value)
    @d[key] = value.to_i.clamp(0, 3)
  end
end

# A project class's `[]=` may store anything (here `9` becomes `3`), so nothing is recorded on it.
def project_class_receiver
  c = ClampedTable.new
  c[:a] ||= 9
  assert_type("Dynamic[top]", c[:a])
  c[:a] += 5
  assert_type("Dynamic[top]", c[:a])
end

# On an `Array` `a[-1]` is the slot `a[0]` names here, so a negative index drops every narrowing and records none.
def negative_index_operator_write
  a = [nil]
  a[0] ||= 0
  a[-1] += 1
  assert_type("Dynamic[top]?", a[0])
end

def negative_index_plain_write
  b = [nil]
  b[0] ||= 0
  b[-1] = 7
  assert_type("Dynamic[top]?", b[0])
end

def negative_index_or_write
  c = [nil]
  c[-1] ||= 0
  c[0] = 5
  assert_type("Dynamic[top]?", c[-1])
end

# A `Hash` tells `-1` from every other key.
def negative_hash_key
  h = { -1 => nil }
  h[-1] ||= 0
  assert_type("0", h[-1])
end

# The rvalue rebinds the receiver, so the store went to the hash `h` named before it ran, and nothing is recorded.
# Ruby reads `nil` from the new hash; the widening still joins the store into it, a reading typed from the entry
# scope (#3100), which reports nothing here.
def rvalue_rebinds_receiver_operator_write
  h = { k: nil }
  h[:k] ||= 0
  h[:k] += (h = { x: 1 }; 1)
  assert_type("Dynamic[top] | Integer", h[:k])
end

def rvalue_rebinds_receiver_or_write
  g = { k: nil }
  g[:k] ||= (g = { x: 1 }; 0)
  assert_type("Dynamic[top] | Integer", g[:k])
end

def conditional_operator_write(cond)
  h = {}
  h[:k] ||= 0
  h[:k] += 1 if cond
  assert_type("0 | 1", h[:k])
end

def branches_write_the_slot(cond)
  h = {}
  h[:k] ||= 0
  if cond
    h[:k] += 1
  else
    h[:k] &&= nil
  end
  assert_type("1?", h[:k])
end

def loop_operator_write(n)
  h = {}
  h[:k] ||= 0
  while n > 0
    h[:k] += 1
    assert_type("Dynamic[top] | Integer", h[:k])
    n -= 1
  end
  assert_type("Dynamic[top] | Integer", h[:k])
end

def block_operator_write
  h = {}
  h[:k] ||= 0
  3.times { h[:k] += 1 }
  assert_type("Dynamic[top] | Integer", h[:k])
end
