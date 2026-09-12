require "rigor/testing"
include Rigor::Testing

# Issue #994 — the union's member absorption reaches INSIDE a structural
# carrier. A same-arity tuple arm that another arm contains element-wise
# is dropped, and so is an identically-shaped hash shape's, so the join
# after a guard names one set instead of several readings of it. See
# docs/type-specification/normalization.md, "Member absorption".
#
# The element-wise clause grants no absorption of its own: it asks the
# same list one level down. Every case below that keeps both arms keeps
# them because the DIRECT union of those two elements keeps both.

# Three arms differing only by what the guard narrowed. The falsy edge of
# a Float comparison keeps the entry type (ADR-109 WD5), so the `else`
# arm is the one that contains the other two.
f = Float(ARGV[0])
three = if f > 0.0
          [f, f.to_s]
        elsif f < 0.0
          [f, f.to_s]
        else
          [f, f.to_s]
        end
assert_type("[Float, String]", three)

# The lift recurses, so a tuple nested inside a tuple collapses too.
g = Float(ARGV[1])
nested = if g > 0.0
           [[g, g.to_s], 1]
         else
           [[g, g.to_s], 1]
         end
assert_type("[[Float, String], 1]", nested)

# A hash shape absorbs over an identical spine: same keys, same
# openness, same required/optional/read-only classification.
h = Float(ARGV[2])
shape = if h > 0.0
          { value: h }
        else
          { value: h }
        end
assert_type("{ value: Float }", shape)

# `IntegerRange` is excluded, because both edges of an Integer
# comparison narrow and the direct union keeps `Integer | Integer[0..5]`.
i = Integer(ARGV[3])
ints = if i.between?(0, 5)
         [i, "x"]
       else
         [i, "x"]
       end
assert_type('[Integer, "x"] | [Integer[0..5], "x"]', ints)

# A value-pinned element is excluded for the reason normalization.md
# keeps `1 | Integer`: the pinned arm records a reachable exact value
# whose provenance the collapse would erase.
j = Integer(ARGV[4])
pinned = ARGV.length.even? ? [1, "x"] : [j, "x"]
assert_type('[1, "x"] | [Integer, "x"]', pinned)

# Differing arity is never absorbed even when every shared position is:
# tuples of different length have disjoint inhabitants.
k = Float(ARGV[5])
arity = ARGV.length.even? ? [k, "x"] : [k.abs]
assert_type('[Float, "x"] | [Float]', arity)

# Neither arm contains the other, so both survive — the rule drops a
# member only when some OTHER member absorbs it.
m = Float(ARGV[6])
disjoint = if m > 1.0
             [m, 1]
           else
             [m.clamp(-1.0, 0.0), 1]
           end
assert_type("[Float[-1.0..0.0], 1] | [Float[1.0..], 1]", disjoint)

# A tuple and an array are different carriers, not two readings of one
# spine.
n = Float(ARGV[7])
not_a_tuple = ARGV.length.even? ? [n, "x"] : ARGV
assert_type('Array[String] | [Float, "x"]', not_a_tuple)

# A hash shape whose key set differs describes a differently-shaped
# hash, so the value types are never compared.
r = Float(ARGV[8])
shape_keys = ARGV.length.even? ? { value: r } : { value: r.abs, extra: 1 }
assert_type("{ value: Float } | { value: Float, extra: 1 }", shape_keys)
