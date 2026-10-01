# frozen_string_literal: true

# https://github.com/rigortype/rigor/issues/1573 — Ruby skips a repeated `extend` of a module already in the
# singleton ancestry, so C.singleton_class.ancestors is [#<Class:C>, E2, E1] and C.foo is the def on line 12.
# Rigor's extend table keeps the later statement's position, so it reads E1 as nearest and takes the def on line 8.

module E1
  def foo = :e1
end

module E2
  def foo = :e2
end

class C
  extend E1
  extend E2
  extend E1
end
