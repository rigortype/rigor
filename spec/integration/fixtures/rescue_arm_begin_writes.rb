require "rigor/testing"
include Rigor::Testing

# Issue #1231 — a `rescue` arm runs after the `begin` body raised from
# some point inside it, so it reads each local the body rebinds at the
# value it held there, not at its value before the `begin`. An `ensure`
# clause runs after such a raise too, as well as after the body and any
# rescue arm finished. Every read below is correct at runtime unless it
# is marked, and nothing but the marked lines may report.

class Conn
  def close = nil
  def size = 0
end

def open_conn = Conn.new

# The issue's shape: the write cannot raise, so every raise the arm
# rescues happens after it.
def rescue_reads_write(s)
  s = String(s)
  state = nil
  begin
    state = s
    Integer(s)
  rescue ArgumentError
    assert_type("String", state)
    return state.length
  end
  0
end

# The everyday shape: `open_conn` may raise before the write, so the arm
# sees the connection or the `nil` it started as.
def rescue_closes_conn(s)
  conn = nil
  begin
    conn = open_conn
    Integer(s)
  rescue ArgumentError
    assert_type("Conn?", conn)
    conn&.close
    conn.size # GENUINE-NIL
  end
end

# A stage flag set between two raising calls reads both values.
def rescue_reads_stage_flag(s)
  parsed = false
  begin
    Integer(s)
    parsed = true
    Float(s)
  rescue ArgumentError
    assert_type("bool", parsed)
    return :late if parsed
  end
  :ok
end

# The same for an instance variable.
class Loader
  def load(s)
    @stage = :start
    begin
      Integer(s)
      @stage = :parsed
      Float(s)
    rescue ArgumentError
      assert_type(":parsed | :start", @stage)
      return :late if @stage == :parsed
    end
    :ok
  end
end

# A write inside a block the body calls is seen by the call's raise.
def rescue_reads_block_write
  current = nil
  begin
    ["1", "x"].each do |item|
      current = item
      Integer(item)
    end
  rescue ArgumentError
    assert_type('"1" | "x" | nil', current)
    return current&.length
  end
  0
end

# `ensure` runs whether or not the body raised: `done` is `false` on the
# raise and `true` otherwise, and only `true` past the `begin`.
def ensure_reads_done_flag(s)
  done = false
  begin
    Integer(s)
    done = true
  ensure
    puts "rolled back" unless done
  end
  assert_type("true", done)
  done
end

# The continuation past `begin … ensure` keeps the body's exit binding.
def ensure_keeps_exit_binding
  x = nil
  begin
    x = 1
  ensure
    puts "cleaned up"
  end
  x + 1
end

# --- A write inside a branch that no rescued raise can follow leaves
# the arm reading the entry value: the branch's test cannot raise after
# the write, and nothing after the branch raises. ---

module Probe
  def self.flaky = Integer("x")
  def self.coin = rand > 0.5
end

def rescue_after_modifier_branch
  x = 1
  begin
    Probe.flaky
    x = nil if Probe.coin
  rescue ArgumentError
    assert_type("1", x)
    x + 1
  end
end

def rescue_after_if_branch
  x = 1
  begin
    Probe.flaky
    if Probe.coin
      x = nil
    end
  rescue ArgumentError
    assert_type("1", x)
    x + 1
  end
end

def rescue_after_branch_and_inert_write
  x = 1
  begin
    Probe.flaky
    x = nil if Probe.coin
    y = 2
  rescue ArgumentError
    assert_type("1", x)
    x + y.to_i
  end
end

class Tally
  def bump
    @x = 1
    begin
      Probe.flaky
      @x = nil if Probe.coin
    rescue ArgumentError
      assert_type("1", @x)
      @x + 1
    end
  end
end

# A write in a test, or in a wrapper that cannot raise, adds no raise
# point after the branch write either: every rescued raise runs first.
def rescue_after_test_capture(s)
  x = 1
  begin
    Probe.flaky
    if (m = s.match(/a/))
      x = nil
    end
  rescue ArgumentError
    assert_type("1", x)
    p(m)
    x + 1
  end
end

def rescue_after_pattern_capture(h)
  x = 1
  begin
    Probe.flaky
    case h
    in { a: } then x = nil
    else
    end
  rescue ArgumentError
    assert_type("1", x)
    p(a)
    x + 1
  end
end

def rescue_after_subject_write
  x = 1
  begin
    Probe.flaky
    case (y = Probe.coin)
    when true then x = nil
    end
  rescue ArgumentError
    assert_type("1", x)
    p(y)
    x + 1
  end
end

def rescue_after_and_test_write(v)
  x = 1
  begin
    Probe.flaky
    if v.nil? && (z = 1)
      x = nil
    end
  rescue ArgumentError
    assert_type("1", x)
    p(z)
    x + 1
  end
end

def rescue_after_unless_test_write(s)
  x = 1
  begin
    Probe.flaky
    x = nil unless (m = s.index("a"))
  rescue ArgumentError
    assert_type("1", x)
    p(m)
    x + 1
  end
end

def rescue_after_mutating_test(arr)
  x = 1
  begin
    Probe.flaky
    if arr << 1
      x = nil
    end
  rescue ArgumentError
    assert_type("1", x)
    x + 1
  end
end

def rescue_after_local_loop(flag)
  x = 1
  begin
    Probe.flaky
    while flag
      x = nil
      flag = false
    end
  rescue ArgumentError
    assert_type("1", x)
    x + 1
  end
end

def rescue_after_and_write
  x = 1
  begin
    Probe.flaky
    Probe.coin && x = nil
  rescue ArgumentError
    assert_type("1", x)
    x + 1
  end
end

def rescue_after_keyword_and_write
  x = 1
  begin
    Probe.flaky
    Probe.coin and x = nil
  rescue ArgumentError
    assert_type("1", x)
    x + 1
  end
end

def rescue_after_parenthesized_write
  x = 1
  begin
    Probe.flaky
    (x = nil)
  rescue ArgumentError
    assert_type("1", x)
    x + 1
  end
end

def rescue_after_ternary_write
  x = 1
  begin
    Probe.flaky
    Probe.coin ? (x = nil) : nil
  rescue ArgumentError
    assert_type("1", x)
    x + 1
  end
end

def rescue_after_nested_begin_write
  x = 1
  begin
    Probe.flaky
    begin
      x = nil
    end
  rescue ArgumentError
    assert_type("1", x)
    x + 1
  end
end

def rescue_after_multiple_write
  x = 1
  y = 1
  begin
    Probe.flaky
    x, y = nil, 2
  rescue ArgumentError
    assert_type("1", x)
    x + y
  end
end

# A raising call after the branch does see its write.
def rescue_after_branch_then_raise
  x = 1
  begin
    x = nil if Probe.coin
    Probe.flaky
  rescue ArgumentError
    assert_type("1?", x)
    x + 1 # GENUINE-NIL
  end
end

# The same after a write in a test.
def rescue_after_test_capture_then_raise(s)
  x = 1
  begin
    if (m = s.match(/a/))
      x = nil
    end
    Probe.flaky
  rescue ArgumentError
    assert_type("1?", x)
    p(m)
    x + 1 # GENUINE-NIL
  end
end

# A loop whose test can raise runs it again after the body wrote.
def rescue_in_loop_test
  x = 1
  begin
    Probe.flaky
    while Probe.coin
      x = nil
    end
  rescue ArgumentError
    assert_type("1?", x)
    x + 1 # GENUINE-NIL
  end
end

# An inner `ensure` runs before the raise it ran after reaches the
# outer arm.
def rescue_after_inner_ensure
  state = :running
  begin
    begin
      Probe.flaky
    ensure
      state = :cleaned
    end
  rescue ArgumentError
    assert_type(":cleaned | :running", state)
    puts "leaked" if state == :running
  end
end

def rescue_after_inner_ensure_flag
  done = false
  begin
    begin
      Probe.flaky
    ensure
      done = true
    end
  rescue ArgumentError
    assert_type("bool", done)
    puts "not done" unless done
  end
end

# An implicit conversion raises before the write after it.
def rescue_in_double_splat(opts)
  x = 1
  begin
    h = { **opts }
    x = nil
    Probe.flaky
  rescue TypeError, ArgumentError
    assert_type("1?", x)
    p(h)
    x + 1 # GENUINE-NIL
  end
end

def rescue_in_splat(z)
  x = 1
  begin
    parts = [*z]
    x = nil
    Probe.flaky
  rescue TypeError, ArgumentError
    assert_type("1?", x)
    p(parts)
    x + 1 # GENUINE-NIL
  end
end

# --- Controls: the arm still reads the entry value where no raise it
# rescues can follow a write. ---

# The body never writes `state`.
def rescue_without_write(s)
  state = nil
  begin
    Integer(s)
  rescue ArgumentError
    return state.length # GENUINE-UNDEFINED
  end
  0
end

# The only write follows the last call that can raise.
def rescue_after_last_raise(s)
  s = String(s)
  state = nil
  begin
    Integer(s)
    state = s
  rescue ArgumentError
    return state.length # GENUINE-UNDEFINED
  end
  0
end

# A flag set after the last raising call is still `false` in the arm.
def rescue_flag_after_last_raise(s)
  parsed = false
  begin
    Integer(s)
    parsed = true
  rescue ArgumentError
    return :late if parsed # GENUINE-FALSEY
  end
  :ok
end
