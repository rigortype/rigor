# A module `extend`ed by the superclass and inherited by its subclass: no fork, no hook, one definer, `Greeter1607s#greet`.
module Greeter1607s
  def greet(name) = name
end

class Host1607s
  extend Greeter1607s
end

class Guest1607s < Host1607s
end

Guest1607s.greet
