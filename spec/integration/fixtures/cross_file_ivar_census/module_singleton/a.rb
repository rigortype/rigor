# Issue #2931 — a module's `def self.x` writes the module object's ivar, so it joins no includer's instance census;
# this file and another file answer the same. Under Ruby 4.0.5 an includer's `@s` is only ever "a" or nil: `SI.x`
# sets `SI`'s own `@s`.
module SI
  def self.x = (@s = 1)
  def set = (@s = "a")
end

module SO
  include SI
  def reset = (@s = nil)
  def peek = assert_type("String?", @s)
end

class SC
  include SI
  def reset = (@s = nil)
  def peek = assert_type("String?", @s)
end

# A module whose only write of `@t` is a `def self.` one joins nothing.
module SOnly
  def self.x = (@t = 1)
end

class SOnlyC
  include SOnly
  def reset = (@t = nil)
  def peek = assert_type("nil", @t)
end

# The module of these is in b.rb.
module SOX
  include SIX
  def reset = (@s = nil)
  def peek = assert_type("String?", @s)
end

class SCX
  include SIX
  def reset = (@s = nil)
  def peek = assert_type("String?", @s)
end
