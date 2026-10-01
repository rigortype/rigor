# The same walk through a module whose surface is its literal definitions: the call fires. The names are this
# file's own: the differential analyses every fixture together, and a class another fixture also declares (`C`,
# `Base`) is a multi-file class whose mixin order the rule declines on (ADR-119 C1b).
module LitD
  def x = nil
end

class LitBase
  include LitD

  def foo(a) = a
end

class LitC < LitBase
  include LitD
end

LitC.new.foo(1, 2)
