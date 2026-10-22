# frozen_string_literal: true

# Issue #1925 — `when nil` runs `nil === subject`, which is `NilClass#===`: it holds for `nil` alone, whatever the
# subject's class defines, so the clause body reads the subject as `nil` and the next clause and the `else` read it
# with `nil` removed, as `when NilClass` does. `when true` and `when false` narrow the same way. Each comment gives
# what Ruby 4.0.5 answers.

# `statement(nil)` returns 0, `statement("a")` "A".
def statement(raw)
  x = raw ? String(raw) : nil
  case x
  when nil
    assert_type("nil", x)
    0
  else
    assert_type("String", x)
    x.upcase
  end
end

# `value(nil)` returns [0], `value("ab")` [2].
def value(raw)
  x = raw ? String(raw) : nil
  [case x when nil then 0 else x.size end]
end

# As a call argument: `argument(nil)` returns [0], `argument("a")` ["A"].
def argument(raw)
  x = raw ? String(raw) : nil
  Array(case x when nil then 0 else x.upcase end)
end

# `when NilClass` reads the same: `class_guard(nil)` returns 0, `class_guard("a")` "A".
def class_guard(raw)
  x = raw ? String(raw) : nil
  case x
  when NilClass then 0
  else x.upcase
  end
end

# `parenthesised(nil)` returns 0, `parenthesised("a")` "A".
def parenthesised(raw)
  x = raw ? String(raw) : nil
  case x
  when (nil) then 0
  else x.upcase
  end
end

# A clause that mixes a condition Rigor reads (`nil`) with one it does not (`""`) reads the subject as
# `Dynamic[top]`, and the `else` reads it as it entered: `with_empty("")` and `with_empty(nil)` return :blank,
# `with_empty("a")` "A".
def with_empty(raw)
  x = raw ? String(raw) : nil
  case x
  when nil, ""
    assert_type("Dynamic[top]", x)
    :blank
  else
    assert_type("String?", x)
    x&.upcase
  end
end

# `in_sequence("a")` returns "A", `in_sequence(nil)` 0, `in_sequence(1)` 1.
def in_sequence(raw)
  x = if raw.is_a?(Integer)
        raw
      else
        (raw ? String(raw) : nil)
      end
  case x
  when String then x.upcase
  when nil
    assert_type("nil", x)
    0
  else
    assert_type("Integer", x)
    x
  end
end

# `false_literal(false)` returns 0, `false_literal(true)` 2; `true_literal(true)` 0, `true_literal(false)` 2.
def false_literal(flag)
  x = flag ? 1 : false
  case x
  when false
    assert_type("false", x)
    0
  else x.succ
  end
end

def true_literal(flag)
  x = flag ? true : 1
  case x
  when true
    assert_type("true", x)
    0
  else x.succ
  end
end

# `nil === subject` never calls the subject's `==` or `===`: `custom(true)` returns 0 and `custom(false)` :else.
class AlwaysEqual
  def ==(_other) = true
  def ===(_other) = true
end

def custom(flag)
  x = flag ? nil : AlwaysEqual.new
  case x
  when nil then 0
  else
    assert_type("AlwaysEqual", x)
    :else
  end
end

# Instance-variable and global subjects narrow as a local does: `CaseWhenNilIvar.new(nil).run` returns 0,
# `CaseWhenNilIvar.new("a").run` "A", `global(nil)` 0 and `global("a")` "A".
class CaseWhenNilIvar
  def initialize(raw)
    @x = raw ? String(raw) : nil
  end

  def run
    case @x
    when nil
      assert_type("nil", @x)
      0
    else
      assert_type("String", @x)
      @x.upcase
    end
  end
end

def global(raw)
  $case_when_nil = raw ? String(raw) : nil
  case $case_when_nil
  when nil
    assert_type("nil", $case_when_nil)
    0
  else
    assert_type("String", $case_when_nil)
    $case_when_nil.upcase
  end
end

# The control: the `when nil` arm reads the subject as `nil`, so a String method there still reports.
# `control(nil)` raises NoMethodError.
def control(raw)
  x = raw ? String(raw) : nil
  case x
  when nil then x.upcase # GENUINE-NIL
  end
end

# The unread condition may itself rule `nil` out, so the mixed clause's body reports no nil receiver:
# `mixed_test("abcd")` returns "ABCD", `mixed_test("b")` nil and `mixed_test(nil)` nil.
def mixed_test(raw)
  x = raw ? String(raw) : nil
  case x
  when /a/, ->(v) { !v.nil? && v.size > 3 } then x.upcase
  end
end

# `when true` / `when false` narrow in a value position too: `false_value(false)` returns [0],
# `false_value(true)` [2]; `true_value(true)` [0], `true_value(false)` [2].
def false_value(flag)
  x = flag ? 1 : false
  [case x
   when false
     assert_type("false", x)
     0
   else
     assert_type("1", x)
     x.succ
   end]
end

def true_value(flag)
  x = flag ? true : 1
  [case x
   when true
     assert_type("true", x)
     0
   else
     assert_type("1", x)
     x.succ
   end]
end

# Once `when Array` and `when nil` cover `[raw]` or `nil`, the `else` is dead and reports, as it does when spelled
# `when NilClass`. `dead_else("a")` returns 1 and `dead_else(nil)` 2. (A `String?` subject would not report: a
# `Pathname` stands in for a `String`, #2071.)
def dead_else(raw)
  x = raw ? [raw] : nil
  case x
  when Array then 1
  when nil then 2
  else 3 # GENUINE-UNREACHABLE
  end
end
