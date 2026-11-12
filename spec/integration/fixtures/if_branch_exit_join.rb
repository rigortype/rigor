require "rigor/testing"
include Rigor::Testing

# Issue #1230 — an `if` / `unless` branch that certainly exits beside
# an `else` never reaches the code after it, so its writes and its
# predicate edge stay out of the scope that follows. Only the branch
# that ran carries on. "Certainly" is syntactic: a `return` / `next` /
# `break` / `redo` / `retry`, a receiver-less Kernel exit call whose
# name no project file defines (this file defines none), or a nested
# if / case whose every arm, else included, certainly exits. The
# project-defined names are in `if_branch_exit_join_project_exits.rb`.
# Nothing in this file reports unless the line is marked.

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

# A then-branch ending in a call to a helper typed `bot` still joins
# beside an else, as on the base: the typer also types an overridable or
# Kernel-shadowing project method `bot` (issue #3110), so a `bot` call
# is no proof of an exit.
def then_calls_bot_helper(c)
  x = maybe
  if c
    x = nil
    die
  else
    x = "s"
  end
  x.upcase # BOT-HELPER-JOINED
end

# A nested if whose every arm exits, else included, exits.
def then_nested_exits(c, d)
  x = maybe
  if c
    x = nil
    if d
      raise "a"
    else
      return
    end
  else
    x = "s"
  end
  x.upcase
end

# So does a case whose every arm, else included, exits.
def then_case_exits(c, k)
  x = maybe
  if c
    x = nil
    case k
    when 1 then raise "a"
    else return
    end
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

# `return` and `exit` end the branch as `raise` does.
def then_returns(c)
  x = maybe
  if c
    x = nil
    return
  else
    x = "s"
  end
  x.upcase
end

def then_exits(c)
  x = maybe
  if c
    x = nil
    exit
  else
    x = "s"
  end
  x.upcase
end

# Both branches exit: the code after is unreachable, and the then-branch's
# exit scope stands, as before.
def both_exit(c)
  x = maybe
  if c
    x = "s"
    raise "e"
  else
    x = nil
    return
  end
  assert_type('"s"', x)
end

# `redo` re-runs the loop body with the branch's writes, so it is no
# exit: the then-branch's nil reaches the code after the loop and
# `x ? 1 : 0` is a real test.
def cond = [true, false].sample

def while_redo
  x = "s"
  while cond
    break if cond
    if cond
      x = nil
      redo
    else
      x = "s"
    end
  end
  x ? 1 : 0
end

def block_redo
  x = "s"
  [1, 2].each do |_i|
    break if cond
    if cond
      x = nil
      redo
    else
      x = "s"
    end
  end
  x ? 1 : 0
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
