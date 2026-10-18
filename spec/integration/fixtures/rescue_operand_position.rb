require "rigor/testing"
include Rigor::Testing

# Issue #1839 — a `begin … rescue` in an operand position, and a rescue
# modifier's fallback, read each name the body (the modifier's
# expression) writes as `Dynamic[top]`, as a statement-level rescue
# clause does, not at the entry binding. `make` returns a String and
# `work` raises, so Ruby takes every rescue clause below. Nothing in
# this file reports unless the line is marked.

def make = "c"
def work = raise("boom")
def take(*values) = values

# A later call argument: an earlier one moved the scope.
def operand_later_argument
  conn = nil
  take(v = 1, begin; conn = make; work; rescue; conn.size; end, v)
end

# The first call argument.
def operand_first_argument
  conn = nil
  take(begin; conn = make; work; rescue; conn.size; end)
end

def operand_ternary(flag)
  conn = nil
  flag ? begin; conn = make; work; rescue; conn.size; end : 0
end

def operand_hash_value
  conn = nil
  { a: begin; conn = make; work; rescue; conn.size; end }
end

def operand_array_element
  conn = nil
  [begin; conn = make; work; rescue; conn.size; end]
end

def operand_interpolation
  conn = nil
  "#{begin; conn = make; work; rescue; conn.size; end}"
end

def operand_and(flag)
  conn = nil
  flag && begin; conn = make; work; rescue; conn.size; end
end

def operand_or(flag)
  conn = nil
  flag || begin; conn = make; work; rescue; conn.size; end
end

def operand_receiver
  conn = nil
  (begin; conn = make; work; rescue; conn.size; end).to_s
end

# An `ensure` clause runs after the arm, so it reads the body's write too.
def operand_ensure
  conn = nil
  take(v = 1, begin; conn = make; work; rescue; 0; ensure; conn.size; end, v)
end

# `else` runs only when the body finished; the arm still reads the write.
def operand_else
  conn = nil
  take(v = 1, begin; conn = make; work; rescue; conn.size; else; 0; end, v)
end

# The arm of a retried `begin` is not widened (#2062). In an operand
# position it is not recorded under the retry edge either, and reads the
# entry binding (`tries` as 0, `conn` as nil): a gap this file pins.
def operand_retry
  tries = 0
  conn = nil
  take(v = 1, begin; tries += 1; conn = make; work; rescue; retry if tries < 3; conn.size; end, v) # RETRY-OPERAND
end

# A `begin` nested in an operand's `begin`.
def operand_nested
  conn = nil
  take(v = 1, begin; begin; conn = make; work; rescue; conn.size; end; work; rescue; conn.size; end, v)
end

# A rescue modifier's fallback reads the expression's write.
def modifier_fallback
  conn = nil
  (conn = make; work) rescue conn.size
end

def modifier_value
  conn = nil
  got = ((conn = make; work) rescue conn)
  assert_type("Dynamic[top]", got)
  got.size
end

def modifier_in_operand
  conn = nil
  take(v = 1, ((conn = make; work) rescue conn.size), v)
end

# The fallback's write carries the expression's binding out.
def modifier_exit_scope
  conn = nil
  (conn = make; work) rescue (saved = conn)
  saved.size
end

# Controls: a name the body never writes keeps its binding.
def operand_unwritten
  conn = nil
  take(v = 1, begin; other = make; work; rescue; conn.size; end, v, other) # GENUINE-UNDEFINED
end

def modifier_unwritten
  conn = nil
  (other = make; work) rescue conn.size # GENUINE-UNDEFINED
  other
end

# A modifier whose expression writes nothing keeps its fallback's reading.
def modifier_no_write
  conn = nil
  got = (work rescue conn)
  assert_type("nil", got)
  got
end

p [operand_later_argument, operand_first_argument, operand_ternary(true), operand_hash_value, operand_array_element,
   operand_interpolation, operand_and(true), operand_or(false), operand_receiver, operand_ensure, operand_else,
   operand_retry, operand_nested, modifier_fallback, modifier_value, modifier_in_operand, modifier_exit_scope,
   modifier_no_write]
