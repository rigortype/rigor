# frozen_string_literal: true

require "stringio"

# Issue #1484 — a `case` with a subject in a value position the evaluator does not enter (an array element, a call
# argument, a receiver) narrows each clause as its statement form does: the body under the clause's narrowed
# subject, the next clause and the `else` under what the clause rules out. Each comment gives what Ruby 4.0.5
# answers.

def id(value) = value

# With `$stdout` rebound to a `File`, `value_positions` returns [[nil], nil, "", [nil], [nil], [nil]]: `STDOUT` is
# neither a `StringIO` nor a `File`, so no arm runs.
def value_positions
  io = STDOUT
  a = [case io when StringIO then io.string end]
  b = id(case io when StringIO then io.string end)
  c = (case io when StringIO then io.string end).to_s
  d = [case $stdout when StringIO then $stdout.string end]
  e = [(case io
        in StringIO then io.string
        else nil
        end)]
  f = [case io when File then io.flock(0) end]
  [a, b, c, d, e, f]
end

# `File` is an `IO`, so the arm reads the subject narrowed to it, and a method `File` lacks still reports.
# `narrowed_control` returns [nil].
def narrowed_control
  io = STDOUT
  [case io when File then io.no_such_method end] # GENUINE-UNDEFINED
end

# `when A, B` narrows the body to the union of its classes: `multiple(1)` returns [2], `multiple(2)` [:t],
# `multiple(3)` [nil].
def multiple(raw)
  v = if raw == 1
        1
      else
        (raw == 2 ? :s : "s")
      end
  [case v
   when Integer, Symbol
     assert_type("1 | :s", v)
     v.succ
   end]
end

# A splat condition narrows nothing: `splat(1, [Integer])` returns [1], `splat("s", [Integer])` [nil].
def splat(raw, list)
  v = raw == 1 ? 1 : "s"
  [case v
   when *list then assert_type('"s" | 1', v)
   end]
end

# The `else` reads the subject every earlier clause ruled out: `else_arm(1)` returns [2], `else_arm(2)` ["S"].
def else_arm(raw)
  v = raw == 1 ? 1 : "s"
  [case v
   when Integer then v.succ
   else
     assert_type('"s"', v)
     v.upcase
   end]
end

# A subject that writes a local binds it before every clause, so no clause reads the type it held before.
# `subject_write("ab")` returns ["AB"], `subject_write(nil)` [nil].
def subject_write(raw)
  x = 1
  [case (x = raw ? String(raw) : nil)
   when String then x.upcase
   end]
end

# Likewise a `when` condition that writes: `condition_write("a")` returns ["A"], `condition_write("b")` [nil].
def condition_write(raw)
  x = 1
  [case raw
   when (x = "a") then x.upcase
   end]
end

# `case … in`: a bare class pattern narrows as `when` does, a capture binds the matched value, and a pattern that
# deconstructs or carries a guard narrows nothing. `in_capture(2)` returns ["SS"], `in_array(1)` [2],
# `in_hash(1)` [1], `in_guard(2, true)` ["s"], `in_later(1)` [2] and `in_later(2)` ["S"]; the
# others return [nil] for the other subject, and `in_guard(2, false)` [nil].
def in_capture(raw)
  v = raw == 1 ? 1 : "s"
  [case v
   in String => s then s.upcase + v.upcase
   else nil
   end]
end

def in_array(raw)
  v = raw == 1 ? [1, 2] : "s"
  [case v
   in [Integer, *] then v.size
   else nil
   end]
end

def in_hash(raw)
  v = raw == 1 ? { a: 1 } : "s"
  [case v
   in { a: } then a
   else nil
   end]
end

def in_guard(raw, cond)
  v = raw == 1 ? 1 : "s"
  [case v
   in String if cond then assert_type('"s" | 1', v)
   else nil
   end]
end

def in_later(raw)
  v = raw == 1 ? 1 : "s"
  [case v
   in String then v.upcase
   in Integer then v.succ
   end]
end

# An instance-variable subject narrows too: `ivar_subject` returns [nil].
def ivar_subject
  @io = STDOUT
  [case @io when File then @io.flock(0) end]
end

# The statement and write forms the evaluator enters stay as they were: `statement_and_write` returns nil.
def statement_and_write
  io = STDOUT
  case io when File then io.flock(0) end
  g = case io when File then io.flock(0) end
  g && nil
end

# A later clause's test reads the subject every earlier clause ruled out: `later_condition(nil)` returns [0],
# `later_condition(1)` [nil].
def later_condition(raw)
  v = raw ? 1 : nil
  [case v
   when NilClass then 0
   when v.succ then 1
   end]
end

# A test that calls a method may rebind an instance-variable subject before the body or the `else` reads it, so
# from that test on the subject is not narrowed. `ResetsBetweenClauses.new(false).body_after_call` returns ["S"],
# `ResetsBetweenClauses.new(false).else_after_call` ["S"]; with `true` each returns [1].
class ResetsBetweenClauses
  def initialize(flag)
    @x = flag ? "a" : nil
  end

  def reset!
    @x = "s"
    ->(_) { true }
  end

  def reset_unmatched!
    @x = "s"
    ->(_) { false }
  end

  def body_after_call
    [case @x
     when String then 1
     when reset! then @x.upcase
     end]
  end

  def else_after_call
    [case @x
     when String then 1
     when reset_unmatched! then 2
     else @x.upcase
     end]
  end

  # With no call in the tests the subject stays narrowed: `ResetsBetweenClauses.new(false).plain` returns [nil].
  def plain
    [case @x
     when String then @x.no_such_method # GENUINE-UNDEFINED
     end]
  end
end
