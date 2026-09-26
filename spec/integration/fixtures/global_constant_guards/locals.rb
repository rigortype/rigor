require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1429 — the same three guards on a local typed `IO`. A class guard whose receiver type has no member that can
# satisfy it narrows the receiver to `Dynamic[C]` instead of `bot`: no `flow.unreachable-clause`, no dropped arm, and the
# arm is gradual. Ruby 4.0.5 answers nil, "" and nil under `STDOUT`.
#
# The base engine was already quiet on `local_is_a` (it read the arm as `bot`) and on `local_case`'s call (it proved the
# clause unreachable, an info diagnostic this entry now asserts is gone); it reported `local_respond_to`.

def local_is_a
  io = STDOUT
  io.is_a?(StringIO) ? io.string : nil # QUIET-1429
end

def local_respond_to
  io = STDOUT
  io.respond_to?(:string) ? io.string : "" # QUIET-1429
end

def local_case
  io = STDOUT
  case io
  when StringIO then io.string # QUIET-1429
  end
end

def local_case_value
  io = STDOUT
  assert_type(":io | Dynamic[:string_io]", (case io when StringIO then :string_io else :io end))
end

# A union with a member that satisfies the guard still selects that member, and a literal keeps its `bot`.
def selection(flag)
  value = flag ? [1] : "s"
  assert_type('"s"', value) if value.is_a?(String)
  literal = 1
  assert_type("bot", literal) if literal.is_a?(String)
end

# An `Integer` the engine inferred is never a `String`, but the guard is evidence, so the arm reads the guarded class,
# gradually, rather than `bot` (Ruby: the arm does not run).
def integer_guard(text)
  size = String(text).to_i
  assert_type("Dynamic[String]", size) if size.is_a?(String)
end
