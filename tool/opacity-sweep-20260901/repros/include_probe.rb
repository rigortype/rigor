module Greeter
  def greeting
    "hello"
  end
end

class Person
  include Greeter
  def name
    "alice"
  end
end

p1 = Person.new.name
p2 = Person.new.greeting
