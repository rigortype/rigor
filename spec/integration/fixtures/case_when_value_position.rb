require "rigor/testing"
include Rigor::Testing

# Issue #2211 — a `case` reads as its statement form in a value position the evaluator does not enter (an array
# element, a call argument, an interpolation), writes in its tests and arms included, and a `when` test that calls a
# method forgets a global subject's narrowing, since the method may assign the global. Each comment gives what Ruby
# 4.0.5 answers. GENUINE-NIL and GENUINE-UNDEFINED mark a call Ruby raises on.

def take(*args, **kwargs) = [args, kwargs]

# A write in an arm is read from where it runs: `arm_write("s")` returns [false] and `arm_write(nil)` [nil], in each
# position.
def arm_write(raw)
  c = raw ? "s" : nil
  [case when c then (c = c.size; assert_type("1", c).even?) end]
end

def arm_write_argument(raw)
  c = raw ? "s" : nil
  take(case when c then (c = c.size; c.even?) end)
end

def arm_write_interpolated(raw)
  c = raw ? "s" : nil
  "#{case when c then (c = c.size; c.even?) end}"
end

def arm_write_subject(raw)
  c = raw ? "s" : nil
  [case c when String then (c = c.size; c.even?) end]
end

# A write in a test binds before the body: `test_write("ab")` returns ["AB"], `subject_write("ab")` ["AB"], and the
# statement twin "AB".
def test_write(raw)
  [case when (x = raw ? String(raw) : nil) then assert_type("String", x).upcase end]
end

def subject_write(raw)
  x = 1
  [case (x = raw ? String(raw) : nil)
   when String then assert_type("String", x).upcase
   end]
end

def subject_write_statement(raw)
  x = 1
  case (x = raw ? String(raw) : nil)
  when String then x.upcase
  end
end

# An instance-variable subject write narrows the same way: `ivar_subject_write("ab")` returns ["AB"].
def ivar_subject_write(raw)
  [case (@case_y = raw ? String(raw) : nil)
   when String then assert_type("String", @case_y).upcase
   end]
end

# A block in an arm reads the arm's narrowing, a `self`-changing one included: `block_arm("s")` returns [[1]],
# `self_block_arm("s")` ["S"].
def block_arm(raw)
  c = raw ? "s" : nil
  [case when c then [1].map { c.size } end]
end

def self_block_arm(raw)
  c = raw ? "s" : nil
  [case when c then c.instance_eval { upcase } end]
end

# A class-creating block in an arm resolves constants in the enclosing module, and a captured write in it is read
# as the block may leave it: `CaseHolder.build(true)[0].new.m` returns 2.
module CaseHolder
  BAZ = 1

  def self.build(raw)
    c = raw ? "s" : nil
    [case when c then Class.new { def m = BAZ.succ } end]
  end

  def self.capture(raw)
    c = raw ? "s" : nil
    [case when c then Class.new { c = c.size; c.even? } end]
  end
end

# The narrowing ends with the `case`: an element after it reads the scope the `case` started in, so
# `sibling(nil)` raises.
def sibling(raw)
  c = raw ? "s" : nil
  [(case when c then c.size end), c.size] # GENUINE-NIL
end

# A genuine nil in an arm still reports: `arm_nil("s")` raises.
def arm_nil(raw)
  c = raw ? "s" : nil
  [case when c then (c = nil; c.even?) end] # GENUINE-UNDEFINED
end

# A `when` test that calls a method forgets a global subject: `global_after_call` returns 6 and
# `global_after_call_element` [6].
def rebind_case_global!
  $case_when_global = 5
  ->(_) { false }
end

def global_after_call
  $case_when_global = nil
  case $case_when_global
  when String then 1
  when rebind_case_global! then 2
  else $case_when_global + 1
  end
end

def global_after_call_element
  $case_when_global = nil
  [case $case_when_global
   when String then 1
   when rebind_case_global! then 2
   else $case_when_global + 1
   end]
end

# The clause bodies after the calling test read the global as the call may leave it too: `global_in_body` returns 6.
def global_in_body
  $case_when_global = nil
  case $case_when_global
  when String then 1
  when rebind_case_global! then 2
  when NilClass then $case_when_global + 1
  end
end

# A subject that writes an instance variable is read through the same rebinding test: `clear!` empties `@cx`
# before the `String` clause matches the stored "ab", so `ClearHolder.new.cleared("ab")` and `.cleared_bare("ab")`
# return nil.
class ClearHolder
  def clear! = (@cx = nil; false)

  def cleared(raw)
    case (@cx = raw ? String(raw) : nil)
    when clear! then 0
    when String then assert_type("String?", @cx)
    end
  end

  def cleared_bare(raw)
    case @cx = raw ? String(raw) : nil
    when clear! then 0
    when String then assert_type("String?", @cx)
    end
  end
end

# Controls. A call-free test keeps the global's narrowing: `global_no_call` raises. A local subject is not
# reassigned by the call: `local_after_call` raises.
def global_no_call
  $case_when_global = nil
  case $case_when_global
  when String then 1
  else $case_when_global + 1 # GENUINE-UNDEFINED
  end
end

def local_after_call
  x = nil
  case x
  when Integer then 1
  when rebind_case_global! then 2
  else x + 1 # GENUINE-UNDEFINED
  end
end
