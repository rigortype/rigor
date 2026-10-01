# The same walk through a module whose surface is its literal definitions: the call fires.
module D
  def x = nil
end

class Base
  include D

  def foo(a) = a
end

class C < Base
  include D
end

C.new.foo(1, 2)
