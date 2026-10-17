require "rigor/testing"
include Rigor::Testing

# Issue #1839 — a rescue clause runs after the `begin` body raised from
# any point in it, so the value it answers, the scope it falls through
# with and a `return`, `next` or `break` it takes all see each name the
# body writes as `Dynamic[top]` (issue #1231's widening), not at the
# `begin`'s entry binding. `make` returns a String and `work` raises, so
# Ruby takes every rescue clause below. Nothing in this file reports
# unless the line is marked.

def make = "c"
def work = raise("boom")

# The issue's `a`: the arm's value is the connection.
def arm_value
  conn = nil
  got = begin
    conn = make
    work
  rescue
    conn
  end
  assert_type("Dynamic[top]", got)
  got.size
end

# The issue's `b`: a write in the arm carries the body's binding out.
def arm_exit_scope
  conn = nil
  begin
    conn = make
    work
  rescue
    saved = conn
  end
  saved.size
end

# The issue's `c`: a `return` from the arm reaches the inferred return.
def arm_return
  r = :a
  begin
    r = :b
    work
  rescue
    return r
  end
  :c
end

def arm_return_caller
  return 1 if arm_return == :b

  2
end

# A name the arm never mentions leaves it widened too: the body may have
# raised after any of its writes, not only after the last.
def arm_unmentioned
  r = :a
  begin
    r = :b
    work
    r = :c
  rescue
    nil
  end
  return 1 if r == :b

  2
end

# An empty arm falls through with its widened entry.
def arm_empty
  r = :a
  begin
    r = :b
    work
    r = :c
  rescue
  end
  return 1 if r == :b

  2
end

# `rescue => e` binds the exception; the body's write still widens.
def arm_reference
  conn = nil
  got = begin
    conn = make
    work
  rescue => e
    assert_type("StandardError", e)
    conn
  end
  got.size
end

# Each of several rescue clauses enters widened.
def arm_multiple
  conn = nil
  got = begin
    conn = make
    work
  rescue TypeError
    conn
  rescue RuntimeError
    conn
  end
  got.size
end

# A `retry` re-enters the body. The arm of a retried `begin` is not
# widened: it reads the retry edge's join of every point the body raises
# from, which carries the write, and the `nil` from before it.
def arm_retry
  tries = 0
  conn = nil
  got = begin
    tries += 1
    conn = make
    work
  rescue
    retry if tries < 3
    conn
  end
  got.size # RETRY-JOIN
end

# `else` runs only when the body finished, so it reads the body's final
# binding, precisely.
def arm_else
  conn = nil
  begin
    conn = make
  rescue
    conn = "fallback"
  else
    assert_type('"c"', conn)
  end
  conn.size
end

# An `ensure` clause's own write flows out of the `begin`.
def ensure_own_write
  begin
    make
  ensure
    done = 1
  end
  done.succ
end

# A `return` from an `ensure` clause leaves after any prefix of the body.
def ensure_return
  r = :a
  begin
    r = :b
    work
  ensure
    return r # RETURN-IN-ENSURE
  end
end

def ensure_return_caller
  return 1 if ensure_return == :b

  2
end

# A method-level `rescue`.
def method_rescue(conn = nil)
  conn = make
  work
rescue
  conn
end

def method_rescue_caller
  method_rescue.size
end

# A `break` out of an arm leaves the loop with the arm's scope.
def arm_break_in_loop
  r = :a
  while true
    begin
      r = :b
      work
      r = :c
    rescue
      break
    end
  end
  return 1 if r == :b

  2
end

# A `next` out of an `ensure` clause inside a loop leaves after any
# prefix of the body.
def ensure_next_in_loop
  r = :a
  i = 0
  while i < 1
    i += 1
    begin
      r = :b
      work
      r = :c
    ensure
      next
    end
  end
  return 1 if r == :b

  2
end

# A `begin … end while` with a rescue clause.
def arm_in_do_while
  r = :a
  i = 0
  begin
    begin
      r = :b
      work
      r = :c
    rescue
      i += 1
    end
  end while i < 2
  return 1 if r == :b

  2
end

# A `next` out of an arm inside a block.
def arm_next_in_block
  r = :a
  got = [1].map do
    begin
      r = :b
      work
      r = :c
    rescue
      next r
    end
  end
  return 1 if got.first == :b

  2
end

# A nested `begin`: the outer arm sees the inner body's write.
def arm_nested
  r = :a
  begin
    begin
      r = :b
      work
      r = :c
    rescue TypeError
      nil
    end
  rescue
    nil
  end
  return 1 if r == :b

  2
end

# A rescue modifier's fallback.
def arm_modifier
  conn = nil
  got = (conn = make; work) rescue conn
  got.size
end

# A write inside a block the body calls counts as the body's.
def arm_block_write
  conn = nil
  begin
    [1].each { conn = make }
    work
  rescue
    conn.size
  end
end

# A `begin` in an operand position.
def arm_in_operand
  conn = nil
  got = [begin
           conn = make
           work
         rescue
           conn
         end]
  got.first.size
end

# A block's `do … rescue … end`.
def arm_in_block
  saved = ""
  conn = nil
  [1].each do
    conn = make
    work
  rescue
    saved = conn
  end
  saved.size
end

# An instance variable the body writes.
class Stage
  def run
    @stage = :start
    begin
      @stage = :parsed
      work
      @stage = :done
    rescue
      nil
    end
    return 1 if @stage == :parsed

    2
  end
end

# A body write narrower than the entry widens, never narrows: past the
# arm `v` is not the body's `1`, since the raise came before the write.
def arm_narrowing_write
  v = ENV.fetch("RIGOR_FIXTURE_UNSET", nil)
  begin
    work
    v = 1
  rescue
    nil
  end
  return 1 if v.nil?

  2
end

# --- Controls ---

# A variable the body never writes keeps its precise type in the arm.
def arm_unwritten_precise
  k = 1
  begin
    make
    work
  rescue
    assert_type("1", k)
  end
end

# A name the body writes once and the arm never mentions keeps the join
# of the entry and that write past the `begin`.
def arm_single_write_precise
  x = :a
  begin
    x = :b
    work
  rescue
    nil
  end
  assert_type(":a | :b", x)
  x
end

# And past the `begin`: the nil the body never replaces still reports.
def arm_unwritten_nil
  x = nil
  begin
    work
  rescue
    nil
  end
  x.size # GENUINE-UNDEFINED
end

# An arm's own write of `nil` is not widened.
def arm_own_nil
  conn = make
  begin
    conn = make
    work
  rescue
    conn = nil
  end
  conn.size if conn
end

p [arm_value, arm_exit_scope, arm_return, arm_return_caller, arm_unmentioned, arm_empty, arm_reference,
   arm_multiple, arm_retry, arm_else, ensure_own_write, ensure_return, ensure_return_caller,
   method_rescue_caller, arm_break_in_loop, ensure_next_in_loop, arm_in_do_while, arm_next_in_block, arm_nested, arm_modifier,
   arm_block_write, arm_in_operand, arm_in_block, Stage.new.run, arm_narrowing_write, arm_single_write_precise, arm_own_nil]
