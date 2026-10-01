# A `def self.` on the receiver's own class.
class Factory
  def self.build(kind) = kind
end

Factory.build(1, 2)
