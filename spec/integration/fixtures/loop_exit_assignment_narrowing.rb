require "rigor/testing"
include Rigor::Testing

# Item 4 / ranked-slice 4 — a `while`/`until` loop exits PRECISELY on its
# predicate's exit edge, so the predicate-assignment target carries the
# exit polarity into the continuation scope. `until line = expr` exits
# when the assignment is truthy, so `line` is non-nil afterward; the bare
# `line.foo` read is clean (previously a `possible nil receiver` FP). A
# `while x = expr` exits when the assignment is falsey, so `x` is nil
# afterward. A `break` in the body voids the exit-edge proof, so the
# target stays nilable.

# `until` exit ⇒ assignment was truthy ⇒ target non-nil.
def until_exit(flag)
  until line = (flag ? "x" : nil)
    nil
  end
  assert_type('"x"', line)
  line.upcase
end

# `while` exit ⇒ assignment was falsey ⇒ target nil.
def while_exit(flag)
  while value = (flag ? "y" : nil)
    nil
  end
  assert_type("nil", value)
end

# `break` voids the proof ⇒ target stays nilable, no narrowing.
def with_break(flag)
  until line = (flag ? "x" : nil)
    break
  end
  assert_type('"x"?', line)
end
