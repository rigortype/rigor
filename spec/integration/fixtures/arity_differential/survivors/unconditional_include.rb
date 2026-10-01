# A plain `include` of a module defining the method; no other class or module carries the name.
module Greets
  def greet(name) = name
end

class Person
  include Greets
end

Person.new.greet
