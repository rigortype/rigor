require "rigor/testing"
include Rigor::Testing

# Issue #1840 — a branch merge that re-joins the narrowed edges of an
# untyped local gives it back its untyped binding.
#
# Narrowing concretizes `Dynamic[top]`: `x.nil?` splits it into `nil` and
# `Dynamic[top]`, `when String` into `String` and `Dynamic[top]`. Joining
# the edges after both left `Dynamic[top] | String | nil`, whose `nil`
# beside a nameable class made `x + "a"` report a possible nil receiver
# on correct code, although neither narrowing alone did. Every quiet
# method below runs without error on a String.

def nil_check_then_case(s)
  x = Marshal.load(s)
  puts "nil" if x.nil?
  case x
  when String then puts "s"
  end
  assert_type("Dynamic[top]", x)
  x + "a"
end

def is_a_elsif_nil(s)
  x = Marshal.load(s)
  if x.is_a?(String)
    puts x
  elsif x.nil?
    puts "nil"
  end
  assert_type("Dynamic[top]", x)
  x + "a"
end

def unless_then_and(s)
  x = Marshal.load(s)
  puts "nil" unless x
  x.is_a?(String) && x.empty?
  assert_type("Dynamic[top]", x)
  x + "a"
end

def ternaries(s)
  x = Marshal.load(s)
  x.nil? ? puts("n") : puts("v")
  x.is_a?(String) ? puts("s") : puts("o")
  assert_type("Dynamic[top]", x)
  x + "a"
end

def case_in_patterns(s)
  x = Marshal.load(s)
  case x
  in nil then puts "n"
  in String then puts "s"
  else puts "o"
  end
  assert_type("Dynamic[top]", x)
  x + "a"
end

def loop_narrowing(s, n)
  x = Marshal.load(s)
  while n > 0
    n -= 1
    next if x.nil?

    puts "s" if x.is_a?(String)
  end
  assert_type("Dynamic[top]", x)
  x + "a"
end

# The pre-branch binding is not `Dynamic[top]` alone, but the inner
# `elsif` merge re-joins the untyped edge the `is_a?` test left.
class Conn
  def close; end
  def size = 0
end

def widened_then_narrowed(s, c)
  x = c ? Conn.new : Marshal.load(s)
  if x.is_a?(Conn)
    x.close
  elsif x.nil?
    puts "nil"
  end
  assert_type("Conn | Dynamic[top]", x)
  x.size
end

# --- Controls: a nil the program puts there still reports. ---

def nil_written_before_case(s, c)
  x = Marshal.load(s)
  x = nil if c
  case x
  when String then puts "s"
  end
  assert_type("Dynamic[top] | String | nil", x)
  x + "a" # GENUINE-NIL
end

def reassigned_after_narrowing(s, c)
  x = Marshal.load(s)
  puts "nil" if x.nil?
  x = c ? "a" : nil
  x + "a" # GENUINE-NIL
end

def nil_written_in_an_arm(s, c)
  x = Marshal.load(s)
  if x.is_a?(String)
    puts x
  elsif c
    x = nil
  end
  assert_type("Dynamic[top] | String | nil", x)
  x + "a" # GENUINE-NIL
end
