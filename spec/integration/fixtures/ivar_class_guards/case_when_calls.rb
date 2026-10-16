require "rigor/testing"
include Rigor::Testing

# Issue #1963 — `case` evaluates its subject once, then runs each `when` test (`test === subject`) in order. A test
# that calls a method runs before the clause's body and every later clause, so a call that may write the subject
# variable leaves it holding something other than the value the tests match: from that test on, no clause narrows the
# variable. Each method here that ends in `!` assigns `@x = "s"`, so under Ruby 4.0.5, with `@x` nil, every quiet
# read returns "S". A lambda literal's `===` runs its body, so its writes count too.
#
# The control keeps the narrowing where the callee is proven to write nothing (#1596), and reports where Ruby 4.0.5
# raises NoMethodError on `nil`.
class CaseWhenCalls
  def initialize(text)
    @x = text ? "a" : nil
  end

  def reset!
    @x = "s"
    ->(_) { true }
  end

  def miss!
    @x = "s"
    ->(_) { false }
  end

  def log(message) = warn(message)

  def pure_match
    log("matching")
    ->(_) { true }
  end

  def statement
    case @x
    when String then 1
    when reset! then @x.upcase # QUIET-1446
    end
  end

  def value_position
    r = case @x
        when String then 1
        when reset! then @x.upcase # QUIET-1446
        end
    r
  end

  def else_arm
    case @x
    when String then 1
    when miss! then 2
    else @x.upcase # QUIET-1446
    end
  end

  def second_test
    case @x
    when String, reset! then @x.upcase # QUIET-1446
    end
  end

  def lambda_writes
    case @x
    when String then 1
    when ->(_) { @x = "s"; true } then @x.upcase # QUIET-1446
    end
  end

  def lambda_calls
    case @x
    when String then 1
    when ->(_) { reset!; true } then @x.upcase # QUIET-1446
    end
  end

  def proven_pure
    case @x
    when String then 1
    when pure_match then @x.upcase # FIRES-1446 call.undefined-method
    end
  end
end

# A test that may rebind the subject variable stops every later clause narrowing it, too: under Ruby 4.0.5, with
# `@n` 1, `miss!` leaves it "s" and `Integer` matches the subject, so the read returns "S".
class LaterClause
  def initialize(int)
    @n = int ? 1 : nil
  end

  def miss!
    @n = "s"
    ->(_) { false }
  end

  def later_clause
    case @n
    when miss! then 0
    when Integer then @n.upcase # QUIET-1446
    end
  end
end

# A global subject: `greset!` assigns `$case_g = "g"`, so under Ruby 4.0.5 the read returns "G".
$case_g = nil

def greset!
  $case_g = "g"
  ->(_) { true }
end

def global_subject
  case $case_g
  when String then 1
  when greset! then $case_g.upcase # QUIET-1446
  end
end

# Issue #1963 item 2 — a local a `when` lambda assigns: under Ruby 4.0.5, with `int` false, the read returns "X".
def lambda_local(int)
  v = int ? 1 : nil
  case v
  when Integer then 1
  when ->(_) { v = "x"; true } then v.upcase # QUIET-1446
  end
end
