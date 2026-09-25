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
