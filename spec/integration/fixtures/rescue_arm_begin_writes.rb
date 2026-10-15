require "rigor/testing"
include Rigor::Testing

# Issue #1231 — a `rescue` arm runs after the `begin` body raised from
# some point inside it, and an `ensure` clause after such a raise as
# well as after the body and any rescue arm finished, so either reads a
# local the body rebinds at a value the scope it enters with does not
# hold. The engine does not track where the body raises: a clause reads
# each name the body writes as `Dynamic[top]`, which reports nothing on
# it. Nothing in this file reports unless the line is marked.

class Conn
  def close = nil
  def size = 0
  def reset = nil
  def work = nil
end

def open_conn = Conn.new
def work = raise("boom")

module Probe
  def self.flaky = Integer("x")
  def self.coin = rand > 0.5
end

# The issue's shape: `conn` is the connection, or the `nil` it started as.
def rescue_closes_conn(s)
  conn = nil
  begin
    conn = open_conn
    Integer(s)
  rescue ArgumentError
    assert_type("Dynamic[top]", conn)
    conn.size
  end
end

# A stage flag set between two raising calls may hold either value.
def rescue_reads_stage_flag(s)
  parsed = false
  begin
    Integer(s)
    parsed = true
    Float(s)
  rescue ArgumentError
    assert_type("Dynamic[top]", parsed)
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
      assert_type("Dynamic[top]", @stage)
      return :late if @stage == :parsed
    end
    :ok
  end
end

# A write inside a block the body calls reaches the arm too.
def rescue_reads_block_write
  current = nil
  begin
    %w[1 x].each do |item|
      current = item
      Integer(item)
    end
  rescue ArgumentError
    return current&.length
  end
  0
end

# The floor: `x` cannot be nil in the arm, since the raise comes before
# the write. A plain join would read `1?` and report the call.
def rescue_before_write
  x = 1
  begin
    Probe.flaky
    x = nil
  rescue ArgumentError
    x.succ
  end
end

# Nor does a narrowing of the floor leave a `nil` behind for the next
# call to report.
def rescue_before_write_narrowed
  x = 1
  begin
    Probe.flaky
    x = 2
  rescue ArgumentError
    puts "nil" if x.nil?
    x + 1
  end
end

# `rescue => e` still binds the exception, even when the body wrote `e`.
def rescue_reference_wins
  e = :none
  begin
    e = :pending
    Probe.flaky
  rescue ArgumentError => e
    assert_type("ArgumentError", e)
    e.message
  end
end

# `ensure` runs whether or not the body raised: `done` is `false` on the
# raise and `true` otherwise, and only `true` past the `begin`.
def ensure_reads_done_flag(s)
  done = false
  begin
    Integer(s)
    done = true
  ensure
    assert_type("Dynamic[top]", done)
    puts "rolled back" unless done
  end
  assert_type("true", done)
  done
end

# A rescue arm's write reaches the `ensure` clause the same way.
def ensure_reads_rescue_write(s)
  state = :running
  begin
    Integer(s)
  rescue ArgumentError
    state = :failed
  ensure
    puts "failed" if state == :failed
  end
  state
end

# The continuation past `begin … ensure` keeps the body's exit binding.
def ensure_keeps_exit_binding
  x = nil
  begin
    x = 1
  ensure
    puts "cleaned up"
  end
  assert_type("1", x)
  x + 1
end

# Issue #1457 — the clause also runs after a `return` out of the body,
# from a scope the fall-through does not show.
def ensure_after_return(a)
  x = nil
  if a
    x = 1
    return
  end
  nil
ensure
  puts "x" if x
end

def ensure_after_loop_return(a)
  x = nil
  while a.shift
    x = 1
    return if a.empty?
  end
  x = nil
ensure
  puts "x" if x
end

# A name the inner `ensure` writes reaches the outer arm untyped too: its
# normal-exit value is not the one a raise leaves.
def rescue_after_inner_ensure_write
  conn = :live
  tag = :init
  begin
    begin
      work
      conn = nil
    ensure
      tag = conn
    end
  rescue StandardError
    assert_type("Dynamic[top]", tag)
    puts tag.size
  end
end

def rescue_after_inner_ensure_reset
  conn = Conn.new
  begin
    begin
      conn.work
      conn.close
      conn = nil
    ensure
      conn&.close
    end
  rescue StandardError
    conn.reset
  end
end

# The arm of a `begin` a `retry` targets is not widened: the retry edge
# already carries every scope the body raises from.
def rescue_retried_counter
  tries = 0
  begin
    tries += 1
    Probe.flaky
  rescue ArgumentError
    assert_type("Integer", tries)
    retry if tries < 3
  end
end

# A `next` out of a widened `ensure` leaves with the plain binding.
def ensure_next_in_loop(items)
  items.map do |item|
    seen = nil
    begin
      seen = item
      Integer(item)
    ensure
      next seen if seen
    end
  end
end

# A widened variable narrows as any untyped value does. Testing it with
# both `is_a?` and `nil?` used to leave `nil` beside `Conn` for the next
# call; since #1840 (#1875) the merge re-joins those edges to
# `Dynamic[top]`, so the call stays quiet.
def rescue_widened_narrowing
  x = Conn.new
  begin
    x = open_conn
    work
  rescue
    if x.is_a?(Conn) then x.close elsif x.nil? then puts "nil" end
    x.size
  end
end

# --- Controls: an arm the body writes nothing for reads the entry
# value, and still reports. ---

def rescue_without_write(s)
  state = nil
  begin
    Integer(s)
  rescue ArgumentError
    return state.length # GENUINE-UNDEFINED
  end
  0
end

def rescue_flag_without_write(s)
  parsed = false
  begin
    Integer(s)
  rescue ArgumentError
    return :late if parsed # GENUINE-FALSEY
  end
  :ok
end

def ensure_flag_without_write(a)
  x = nil
  begin
    return if a
  ensure
    puts "x" if x # GENUINE-FALSEY
  end
end
