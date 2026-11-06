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

# Issue #2487 — a module's own census takes the modules it includes or prepends: `Inner2` is on the chain of every
# class that includes `Outer2`, so after `reset; set` on any includer Ruby 4.0.5 returns "A" from `get`.
module Inner2
  def set = (@m = "a")
end

module Outer2
  include Inner2
  def reset = (@m = nil)
  def get = @m.upcase
  def peek = assert_type("\"a\"?", @m)
end

# One module included by a class and by another module joins both censuses.
module Shared
  def set = (@sh = "a")
end

module SharedOuter
  include Shared
  def reset = (@sh = nil)
  def get = @sh.upcase
end

class SharedBox
  include Shared
  def initialize = (@sh = nil)
  def get = @sh.upcase
end

module PreInner
  def set = (@pm = "a")
end

module PreOuter
  prepend PreInner
  def reset = (@pm = nil)
  def get = @pm.upcase
end

# `extend` puts `ExtInner#set` on the module object, not on its includers' instances: Ruby 4.0.5 raises
# NoMethodError on `get` after `reset` on any includer.
module ExtInner
  def set = (@em = "a")
end

module ExtOuter
  extend ExtInner
  def reset = (@em = nil)
  def get = @em.upcase # FIRES call.undefined-method
end

# Review m5 — an ancestor joins its writes as they stand before its read-before-write `nil`: `RbwM#peek` reads `@w`
# before any write in that method, which adds `nil` to `RbwM`'s own entry but not to `RbwK`'s.
module RbwM
  def peek = @w.to_s
  def set = (@w = "a")
end

class RbwK
  include RbwM
  def initialize = (@w = "b")
  def typed = assert_type("\"a\" | \"b\"", @w)
end
