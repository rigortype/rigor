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

# A test that may rebind the subject stops a later, call-free clause narrowing it, whatever rebinds it: a call that
# assigns a global, a lambda that assigns a local, a lambda that assigns an instance variable. Under Ruby 4.0.5, with
# `$case_g` nil and `int` false, the reads return "G", "X" and "S".
def gmiss!
  $case_g = "g"
  ->(_) { false }
end

def global_later_clause
  case $case_g
  when gmiss! then 0
  when NilClass then $case_g.upcase # QUIET-1446
  end
end

def lambda_local_later_clause(int)
  v = int ? 1 : nil
  case v
  when ->(_) { v = "x"; false } then 0
  when NilClass then v.upcase # QUIET-1446
  end
end

class LambdaLaterClause
  def initialize(int)
    @n = int ? 1 : nil
  end

  def later_clause
    case @n
    when ->(_) { @n = "s"; false } then 0
    when NilClass then @n.upcase # QUIET-1446
    end
  end
end

# A lambda test that assigns a global the earlier clause narrowed: under Ruby 4.0.5, with `$case_g` nil, the read
# returns "G".
def global_lambda_test
  case $case_g
  when String then 1
  when ->(_) { $case_g = "g"; true } then $case_g.upcase # QUIET-1446
  end
end

# Issue #1963 review — a call the proof cannot clear (`items.any?` reads an attribute through a local-receiver
# call) forgets the narrowing inside a `when` test without making the variable's declared `nil` reportable:
# under Ruby 4.0.5 `Tagged.new.tagged` returns "T".
class Tagged
  attr_reader :items

  def initialize
    @tag = "t"
    @items = [1]
  end

  def clear_tag = (@tag = nil)
  def any_item = ->(_) { items.any? }

  def tagged
    return unless @tag

    case 1
    when any_item
      t = @tag
      t.upcase # QUIET-1446
    end
  end
end

# The rebinding test is read without a narrowing to move: a lambda that assigns an untyped local, and another
# object's method that assigns `self`'s instance variable, which only the class-guard restore notices. Under Ruby
# 4.0.5 `untyped_local(nil)` returns "X" and `Reflected.new(false).later_clause` returns "S".
def untyped_local(v)
  case v
  when ->(_) { v = "x"; false } then 0
  when NilClass then v.upcase # QUIET-1446
  end
end

class Reflector
  def self.matcher(target)
    target.instance_variable_set(:@n, "s")
    ->(_) { false }
  end
end

class Reflected
  def initialize(int)
    @n = int ? 1 : nil
  end

  def later_clause
    case @n
    when Integer then 0
    when Reflector.matcher(self) then 1
    when NilClass then @n.upcase # QUIET-1446
    end
  end
end

# A lambda test whose body calls a method that assigns the subject: under Ruby 4.0.5
# `LambdaCall.new(false).later_clause` returns "S".
class LambdaCall
  def initialize(int)
    @n = int ? 1 : nil
  end

  def reset_n!
    @n = "s"
  end

  def later_clause
    case @n
    when ->(_) { reset_n!; false } then 0
    when NilClass then @n.upcase # QUIET-1446
    end
  end
end

# A `when` test whose call the proof cannot clear: a narrowing that kept `nil` widens without the mark, so the read
# after it still reports where Ruby 4.0.5 raises (`NilTagged.new.after_return`). A lambda literal's body runs as the
# test's `===`, so a call in it that assigns the variable ends a narrowing to `nil`: `LambdaReset.new.in_if` and
# `LambdaReset.new.after_return` return "S".
class NilTagged
  attr_reader :items

  def initialize
    @tag = nil
    @items = [1]
  end

  def name_tag = (@tag = "t")
  def ready? = items.any?

  def after_return
    return if @tag

    case 1
    when ready? then 0
    end
    t = @tag
    t.upcase # FIRES-1446 call.possible-nil-receiver
  end
end

class LambdaReset
  def initialize
    @x = nil
  end

  def reset!
    @x = "s"
  end

  def in_if
    if @x.nil?
      case 1
      when ->(_) { reset!; true } then @x.upcase # QUIET-1446
      end
    end
  end

  def after_return
    return if @x

    case 1
    when ->(_) { reset!; true } then @x.upcase # QUIET-1446
    end
  end
end
