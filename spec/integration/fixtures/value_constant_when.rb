require "rigor/testing"
include Rigor::Testing

# Issue #1963 — a `when` test or `===` receiver narrows the subject by class only when the constant names a class or
# module. A value constant matches by its value's `===`, which this fixture's reading leaves unnarrowed: under Ruby
# 4.0.5 `value_when(3)` returns 3, `value_when("x")` returns "x", and `alias_when("x")` returns "x".
LIMIT = 3
NAME = "x"
TEXT = String

def value_when(v)
  v = v == 3 ? 3 : "x"
  case v
  when LIMIT then assert_type('"x" | 3', v)
  when NAME then assert_type('"x" | 3', v)
  end
end

def value_position(v)
  v = v == 3 ? 3 : "x"
  r = case v
      when LIMIT then v
      end
  assert_type('"x" | 3 | nil', r)
end

def value_receiver(v)
  v = v == 3 ? 3 : "x"
  assert_type('"x" | 3', v) if LIMIT === v
end

def alias_when(v)
  v = v == 3 ? 3 : "x"
  case v
  when TEXT then assert_type('"x"', v)
  else assert_type("3", v)
  end
end

def alias_receiver(v)
  v = v == 3 ? 3 : "x"
  assert_type('"x"', v) if TEXT === v
end
