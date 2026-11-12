require "rigor/testing"
include Rigor::Testing

# Issue #1230 — an `if` / `unless` branch that unconditionally exits
# beside an `else` never reaches the code after it, so its writes and
# its predicate edge stay out of the scope that follows. Only the
# branch that ran carries on. Nothing in this file reports unless the
# line is marked.

def maybe = [nil, "a"].sample
def die = raise("x")

# The issue's shape: the then-branch writes nil and raises.
def then_raises(c)
  x = maybe
  if c
    x = nil
    raise "e"
  else
    x = "s"
  end
  assert_type('"s"', x)
  x.upcase
end

# The then-branch ends in a call to a helper typed `bot`.
def then_calls_bot_helper(c)
  x = maybe
  if c
    x = nil
    die
  else
    x = "s"
  end
  x.upcase
end

# The unless form.
def unless_body_raises(c)
  x = maybe
  unless c
    x = nil
    raise "e"
  else
    x = "s"
  end
  x.upcase
end

# Narrowing: only the else's predicate edge survives.
def then_raises_on_nil
  x = maybe
  if x.nil?
    raise "e"
  else
    1
  end
  assert_type('"a"', x)
  x.upcase
end

def unless_raises_on_falsey
  x = maybe
  unless x
    raise "e"
  else
    1
  end
  x.upcase
end

# A ternary is an `if`.
def ternary_raises(c)
  x = maybe
  c ? (raise "e") : (x = "s")
  x.upcase
end

# A middle `elsif` branch that exits drops out of the chain's join.
def elsif_raises(c, d)
  x = maybe
  if c
    x = "s"
  elsif d
    x = nil
    raise "e"
  else
    x = "t"
  end
  x.upcase
end

# `next` leaves the iteration, as the no-else arm already counts it.
def then_nexts(items)
  items.each do |c|
    x = maybe
    if c
      x = nil
      next
    else
      x = "s"
    end
    x.upcase
  end
end

# Control: a branch that exits only conditionally still joins.
def then_raises_conditionally(c, d)
  x = maybe
  if c
    x = nil
    raise "e" if d
  else
    x = "s"
  end
  x.upcase # CONDITIONAL-EXIT
end
