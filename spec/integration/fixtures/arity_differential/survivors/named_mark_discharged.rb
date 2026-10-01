# A conditional `include` of a module that cannot answer the name: the mark is discharged for `foo`, Ruby raises in
# both worlds (`NamedBase#foo(x)` runs whether or not `NamedQ` is mixed in), and the call keeps firing.
module NamedQ
  def bar = 1
end

class NamedBase
  def foo(x) = x
end

class NamedC < NamedBase
  include NamedQ if ENV["NAMED_Q"]
end

NamedC.new.foo
