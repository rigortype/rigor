# #1570: Ruby skips `C`'s `include M` (`Base` already carries it), so `C.new.foo` is `Base#foo` and correct; the
# tables cannot tell that from a reopened `Base`, where `M#foo(x)` answers. Master fired on line 22 (the false
# positive); since ADR-119 C1b the rule declines there. Line 23 is the control and keeps firing.
module M
  def foo(x) = "m#{x}"
end

class Base
  include M

  def foo = 1
end

class C < Base
  include M
end

class E
  def foo = 1
end

C.new.foo
E.new.foo(1)
