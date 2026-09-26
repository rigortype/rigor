require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1429 — the same three guards on a local typed `IO`. A class guard disjoint from the receiver's inferred
# `Nominal` narrows the arm to `bot`, as before; the change is that the `case` form no longer reports
# `flow.unreachable-clause`, since the `when` is evidence the subject can hold a `StringIO`. Ruby 4.0.5 answers nil, ""
# and nil under `STDOUT`.
#
# The base engine was already quiet on `local_is_a` and on `local_case`'s call (it proved the clause unreachable, an
# info diagnostic this entry now asserts is gone); it reported `local_respond_to`.

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

# The value drops the arm (Ruby: :io under `STDOUT`). Keeping it is #1465.
def local_case_value
  io = STDOUT
  assert_type(":io", (case io when StringIO then :string_io else :io end))
end

# A union with a member that satisfies the guard still selects that member, and a disjoint guard reads `bot` on a
# literal and on an inferred `Nominal` alike.
def selection(flag, text)
  value = flag ? [1] : "s"
  assert_type('"s"', value) if value.is_a?(String)
  literal = 1
  assert_type("bot", literal) if literal.is_a?(String)
  size = String(text).to_i
  assert_type("bot", size) if size.is_a?(String)
end

# `instance_of?` holds the exact class it names, so a class below the receiver's narrows to it (it read `bot` before).
def instance_of_subclass
  number = Numeric.new
  assert_type("Integer", number) if number.instance_of?(Integer)
end
