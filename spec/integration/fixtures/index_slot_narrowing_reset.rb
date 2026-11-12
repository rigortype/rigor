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
