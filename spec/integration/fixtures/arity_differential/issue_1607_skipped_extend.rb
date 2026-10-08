# #1607: Ruby skips `C1607`'s `extend M1607` (`Base1607`'s singleton already carries it), so `C1607.foo` is
# `Base1607.foo`; the tables cannot tell that from a reopened `Base1607`, where `M1607#foo(x)` answers. Master fired on
# line 23 (the false positive); since ADR-119 C2-c the rule declines. Line 24 is the control. The names are this
# file's own.
module M1607
  def foo(x) = "m#{x}"
end

class Base1607
  extend M1607

  def self.foo = 1
end

class C1607 < Base1607
  extend M1607
end

class E1607
  def self.foo = 1
end

C1607.foo
E1607.foo(1)
