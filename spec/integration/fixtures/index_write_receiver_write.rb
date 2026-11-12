require "rigor/testing"
include Rigor::Testing

# Issue #1272 — Ruby evaluates a compound index write's receiver, then its
# index arguments, then the rvalue, so a variable written in the receiver
# (`(h ||= {})[k] ||= v`) or in an index (`h[(i = 1)] ||= v`) holds its new
# value afterwards. The evaluator typed only the rvalue, so `h` stayed `nil`
# and `h.fetch(k)` reported a call on `nil`. Nothing in this file reports
# unless the line is marked.

def local_or_write(k)
  h = nil
  (h ||= {})[k] ||= 1
  assert_type("Hash[Dynamic[top], Dynamic[top] | Integer]", h)
  h.fetch(k)
end

def local_symbol_slot
  h = nil
  (h ||= {})[:a] ||= 1
  assert_type("Hash[Dynamic[top] | Symbol, Dynamic[top] | Integer]", h)
  h.fetch(:a)
end

def ivar_or_write
  @h = nil
  (@h ||= {})[:a] ||= 1
  assert_type("Hash[Dynamic[top] | Symbol, Dynamic[top] | Integer]", @h)
  @h.fetch(:a)
end

class CvarHolder
  def cvar_or_write(k)
    @@h = nil
    (@@h ||= {})[k] ||= 1
    @@h.fetch(k)
  end
end

def gvar_or_write
  $index_write_receiver = nil
  ($index_write_receiver ||= {})[:a] ||= 1
  $index_write_receiver.fetch(:a)
end

# A plain assignment in the receiver of a compound write.
def assign_receiver(k)
  (h = {})[k] ||= 1
  assert_type("Hash[Dynamic[top], Dynamic[top] | Integer]", h)
  h.fetch(k)
end

# A plain `[]=` is a call, whose receiver was already threaded (#1223).
def assign_receiver_plain_store(k)
  (h = {})[k] = 1
  assert_type("Hash[Dynamic[top], Dynamic[top] | Integer]", h)
  h.fetch(k)
end

# `&&=` and `+=` take the same path as `||=`.
def and_write
  x = nil
  (x ||= {})[:a] &&= 1
  x.fetch(:a)
end

def operator_write
  x = nil
  (x ||= Hash.new(0))[:a] += 1
  x.fetch(:a)
end

# A write in an index argument binds too.
def index_argument_write(h)
  h[(i = 1)] ||= 2
  assert_type("1", i)
  i.succ
end

# A write the receiver may skip leaves the variable possibly unbound.
def conditional_receiver(cond, other)
  (cond ? (h = {}) : other)[1] ||= 2
  assert_type("Hash[Dynamic[top] | Integer, Dynamic[top] | Integer]?", h)
  h.fetch(1) # GENUINE-NIL
end

# The value the expression yields, and an operand position.
def value_position(k)
  h = nil
  y = ((h ||= {})[k] ||= 1)
  puts((h ||= {})[k] ||= 2)
  [h.fetch(k), y]
end
