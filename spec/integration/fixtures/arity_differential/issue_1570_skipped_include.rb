# #1570: Ruby skips `C1570`'s `include M1570` (`Base1570` already carries it), so `C1570.new.foo` is `Base1570#foo`;
# the tables cannot tell that from a reopened `Base1570`, where `M1570#foo(x)` answers. Master fired on line 22 (the
# false positive); since ADR-119 C1b the rule declines. Line 23 is the control. The names are this file's own.
module M1570
  def foo(x) = "m#{x}"
end

class Base1570
  include M1570

  def foo = 1
end

class C1570 < Base1570
  include M1570
end

class E1570
  def foo = 1
end

C1570.new.foo
E1570.new.foo(1)
