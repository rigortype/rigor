require "rigor/testing"
include Rigor::Testing

# `assert <target> is T` — refines `value` unconditionally
# at the post-call scope. Mirrors a `must_be!` /
# `validate_string!` pattern.
def f(value)
  c = Checker.new
  c.must_be_string!(value)
  assert_type("String", value)
end

# `assert-if-true` / `assert-if-false` — refines `value` only
# when the call is observed as a truthy / falsey predicate.
# This is the predicate twin of `assert`: useful for
# `valid_string?` / `integer?`-style helpers whose return
# value documents what the argument must have been.
def g(value)
  c = Checker.new
  if c.integer?(value)
    assert_type("Integer", value)
  else
    assert_type("NilClass", value)
  end
end
