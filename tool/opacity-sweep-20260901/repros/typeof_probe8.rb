module Ent
  MAP = { 42 => "a" }

  def entity(x)
    MAP[42]
  end
  module_function :entity

  def self.direct(x)
    MAP[42]
  end
end

Ent.entity(1)
Ent.direct(1)
