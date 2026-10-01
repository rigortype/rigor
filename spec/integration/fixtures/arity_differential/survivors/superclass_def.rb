# A `def` in the superclass, called through a subclass.
class Parent
  def one(a) = a
end

class Child < Parent
end

Child.new.one
