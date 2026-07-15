require "rigor/testing"
include Rigor::Testing

# Hash literals whose keys are value-pinned scalar literals beyond Symbol / String —
# Integer, Float, `true`, `false`, `nil` — lift to a `HashShape` carrier too, with
# duplicate literal keys resolved LAST-WINS (the runtime keeps the last entry; Ruby
# itself only warns under `-w`). Key identity follows `Hash#eql?`: `1` and `1.0` are
# DISTINCT keys, while `1.0` and `1.00` are the same key.
h = { 1 => 1, 1 => 2, 1.0 => 3, 1.00 => 4 }
assert_type("{ 1 => 2, 1.0 => 4 }", h)

int_hit = h[1]
float_hit = h[1.0]
miss = h[9]
assert_type("2", int_hit)
assert_type("4", float_hit)
assert_type("nil", miss)

ks = h.keys
assert_type("[1, 1.0]", ks)

present = h.key?(1.00)
absent = h.key?(2)
assert_type("true", present)
assert_type("false", absent)

# The bool / nil singletons are valid static keys as well.
b = { true => :yes, false => :no, nil => :none }
assert_type("{ true => :yes, false => :no, nil => :none }", b)
truthy = b[true]
none = b[nil]
assert_type(":yes", truthy)
assert_type(":none", none)

# Symbol-keyed duplicates are last-wins too (previously the whole literal degraded
# to `Hash[Symbol, 1 | 2]`, polluting the value union with the overwritten 1).
s = { a: 1, a: 2 }
assert_type("{ a: 2 }", s)
