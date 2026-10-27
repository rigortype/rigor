# Issue #2170 — a module's instance `def` writes the ivar on the instances of every class that includes or prepends
# it, and a superclass's on its subclasses'. Under Ruby 4.0.5 each quiet `get` returns "A" after `set`, and each
# reporting one raises NoMethodError on `nil`.
module M
  def set = (@x = "a")
end

class Box
  include M
  def initialize = (@x = nil)
  def get = @x.upcase
  def typed = assert_type("\"a\"?", @x)
end

module P
  def set = (@y = "a")
end

class PBox
  prepend P
  def initialize = (@y = nil)
  def get = @y.upcase
end

module Inner
  def set = (@v = "a")
end

module Outer
  include Inner
end

class Nested
  include Outer
  def initialize = (@v = nil)
  def get = @v.upcase
end

class Base
  def set = (@u = "a")
end

class Sub < Base
  def initialize = (@u = nil)
  def get = @u.upcase
end

# Out of scope (#1958 item 2): the hook's `define_method` runs on the includer, but chain crediting does not read it.
module Hooked
  def self.included(base) = base.class_eval { define_method(:set) { @w = "a" } }
end

class HookBox
  include Hooked
  def initialize = (@w = nil)
  def get = @w.upcase # FIRES call.undefined-method
end

class Control
  def initialize = (@c = nil)
  def get = @c.upcase # FIRES call.undefined-method
end

module Unrelated
  def set = (@other = "a")
end

class Includes
  include Unrelated
  def initialize = (@i = nil)
  def get = @i.upcase # FIRES call.undefined-method
end

module Extended
  def set = (@e = "a")
end

class Extends
  extend Extended
  def initialize = (@e = nil)
  def get = @e.upcase # FIRES call.undefined-method
end

module SingletonWriter
  def self.set = (@s = "a")
end

class SingletonIncluder
  include SingletonWriter
  def initialize = (@s = nil)
  def get = @s.upcase # FIRES call.undefined-method
end
