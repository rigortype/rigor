require "rigor/testing"
include Rigor::Testing

# Item 1 / ranked-slice 1 — a `case` whose `else` (or a `when`) branch
# terminates (`raise`/`return`/`throw` ⇒ `Bot`) must not nil-inject the
# locals a live sibling branch assigned. Control never falls through the
# terminating branch, so `v` is `"a" | "b"`, not `... | nil`, and the
# bare `v.upcase` read is clean.
def classify(kind)
  case kind
  when 1 then v = "a"
  when 2 then v = "b"
  else raise ArgumentError
  end
  assert_type('"a" | "b"', v)
  v.upcase
end
