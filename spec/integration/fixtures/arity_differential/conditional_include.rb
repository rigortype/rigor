# An `include` inside control flow: the arity rule walks through the module.
module CondMod
  def go(a) = a
end

class CondInc
  include CondMod if RUBY_VERSION > "3"
end

CondInc.new.go(1, 2)
