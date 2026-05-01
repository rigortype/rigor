require "rigor/testing"
include Rigor::Testing

# `assert value is ~NilClass` — the post-call scope MUST drop
# nil from the union bound to `value`. Mirrors a
# `must_not_be_nil!` / `present!` pattern.
def must_not_nil
  x = nil
  x = 1 if rand < 0.5
  c = Checker.new
  c.must_not_be_nil!(x)
  assert_type("1", x)
end

# `predicate-if-true value is ~NilClass` together with
# `predicate-if-false value is NilClass` produces TypeIs-
# style two-edge narrowing for a `present?` helper.
def present_check
  x = nil
  x = "hi" if rand < 0.5
  c = Checker.new
  if c.present?(x)
    assert_type('"hi"', x)
  else
    assert_type("nil", x)
  end
end
