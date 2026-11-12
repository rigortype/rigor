require "rigor/testing"
include Rigor::Testing

# Issue #1230 — the then-exits-beside-an-else arm accepts a receiver-less
# `raise` / `fail` / `exit` / `exit!` / `abort` / `throw` only when no
# project file defines a method of that name. This file defines `fail`,
# `exit`, `raise` and `halt!`, so none of the branches below is proven to
# exit beside an else and each joins, as on the base. Nothing reports
# unless the line is marked.

def maybe = [nil, "a"].sample

# `fail` and `exit` here return, so the then-branch's nil reaches the code
# after the if and `x ? … : 0` is a real test.
class Collector
  def initialize = @errors = []
  def fail(msg) = @errors << msg
  def exit = @done = true

  def then_fails(c)
    x = maybe
    if c
      x = nil
      fail("bad")
    else
      x = "s"
    end
    assert_type('"s"?', x)
    x ? x.size : 0
  end

  def then_exits(c)
    x = maybe
    if c
      x = nil
      exit
    else
      x = "s"
    end
    x ? x.size : 0
  end
end

# A `bot` helper a project subclass overrides may return on the subclass.
class Base
  def handle = raise(NotImplementedError)

  def run(c)
    x = maybe
    if c
      x = nil
      handle
    else
      x = "s"
    end
    x ? x.size : 0
  end
end

class Sub < Base
  def handle = 1
end

# A `bot` guard a subclass overrides with another raise keeps the base's
# narrowing on the no-else arm.
class Guard2
  def halt!(msg) = raise(ArgumentError, msg)

  def run
    y = maybe
    halt!("n") if y.nil?
    y.upcase
  end
end

class Guard2Sub < Guard2
  def halt!(msg) = raise(KeyError, msg)
end

# A project `raise` that forwards to Kernel's keeps the base's narrowing on
# the no-else arm; beside an else it joins, as on the base.
class Wrap
  def raise(*args) = super

  def guarded
    y = maybe
    raise "n" if y.nil?
    y.upcase
  end

  def beside_else(c)
    x = maybe
    if c
      x = nil
      raise "e"
    else
      x = "s"
    end
    x.upcase # PROJECT-NAME-JOINED
  end
end
