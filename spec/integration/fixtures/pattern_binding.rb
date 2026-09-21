require "rigor/testing"
include Rigor::Testing

# Issue #1122 — a `case/in` pattern binds its names against the SUBJECT, not the `Dynamic[top]`
# floor. The subject's type reaches the pattern through the same carriers the multi-write binder
# decomposes (`Tuple`, `Array[T]`), through the subject's own `deconstruct` / `deconstruct_keys`
# (`Struct`, a `Data` instance, a project class that defines them), and through the pattern's own
# class constraint when the subject's type names nothing. A subject none of those decompose keeps
# the `Dynamic[top]` floor per name, and no line here may draw a diagnostic.

# --- positional patterns -------------------------------------------------

# A literal tuple: the slots ARE the tuple's elements.
case [1, "a"]
in [i, s]
  assert_type("1", i)
  assert_type("\"a\"", s)
end

# A `Tuple`-typed binding reads the same way.
pair = [1, "a"]
case pair
in [first, second]
  assert_type("1", first)
  assert_type("\"a\"", second)
end

# An `Array[T]` subject binds `T` per slot — the same per-element read `a, b = arr` makes.
case ARGV
in [head, tail]
  assert_type("String", head)
  assert_type("String", tail)
end

# A named rest captures the middle elements the fixed slots did not, at the tuple's own types.
case [1, "a", 3]
in [leading, *rest]
  assert_type("1", leading)
  assert_type("[\"a\", 3]", rest)
end

# A find pattern's requireds may sit anywhere the surrounding splats allow, so each binds the
# union of its candidate positions; the surrounding splats bind `Array` of the element type.
case [1, "a", 3]
in [*, middle, *]
  assert_type("\"a\" | 1 | 3", middle)
end

case ARGV
in [*pre, found, *post]
  assert_type("String", found)
  assert_type("Array[String]", pre)
  assert_type("Array[String]", post)
end

# --- hash patterns ------------------------------------------------------

config = { name: "x", age: 1 }
case config
in { name: name, age: age }
  assert_type("\"x\"", name)
  assert_type("1", age)
end

case config
in { name: captured, **rest }
  assert_type("\"x\"", captured)
  assert_type("Hash[Symbol, \"x\" | 1]", rest)
end

# A constrained slot narrows its own binding, on an opaque subject as much as on a known one.
def constrained(value)
  case value
  in { name: String => name, age: Integer => age }
    assert_type("String", name)
    assert_type("Integer", age)
  end
end

# --- the rightward forms ------------------------------------------------

[1, "a"] => [right_x, right_y]
assert_type("1", right_x)
assert_type("\"a\"", right_y)

if [1, "a"] in [pred_x, pred_y]
  assert_type("1", pred_x)
  assert_type("\"a\"", pred_y)
end

# --- deconstruct / deconstruct_keys -------------------------------------

Point = Struct.new(:x, :y)

case Point.new(1, 2)
in [point_x, point_y]
  assert_type("1", point_x)
  assert_type("2", point_y)
end

case Point.new(1, 2)
in { x: member_x, y: member_y }
  assert_type("1", member_x)
  assert_type("2", member_y)
end

Sealed = Data.define(:x, :y)

case Sealed.new(1, 2)
in [sealed_x, sealed_y]
  assert_type("1", sealed_x)
  assert_type("2", sealed_y)
end

# A project class that defines `deconstruct` / `deconstruct_keys` answers through its own body.
# A body that reads ivars the class-ivar table can only see as `Dynamic[top]` answers the floor
# instead, exactly as `Pair.new(1, "a").deconstruct` types at a call site.
class LiteralPair
  def deconstruct
    [1, "a"]
  end

  def deconstruct_keys(keys)
    { left: 1, right: "a" }
  end
end

case LiteralPair.new
in [literal_x, literal_y]
  assert_type("1", literal_x)
  assert_type("\"a\"", literal_y)
end

case LiteralPair.new
in { left: literal_left }
  assert_type("1", literal_left)
end

# --- the floor ----------------------------------------------------------

# Nothing here can decompose a `Dynamic[top]` subject, so every name keeps the floor rather than
# claiming a type the pattern never established.
def opaque(value)
  case value
  in [opaque_a, opaque_b]
    assert_type("Dynamic[top]", opaque_a)
    assert_type("Dynamic[top]", opaque_b)
  end
end

# A `String` subject cannot match a positional pattern at all; the body is unreachable, and the
# names stay at the floor rather than borrow a type from the pattern's own constraints.
case "not a pair"
in [never_a, never_b]
  assert_type("Dynamic[top]", never_a)
end
