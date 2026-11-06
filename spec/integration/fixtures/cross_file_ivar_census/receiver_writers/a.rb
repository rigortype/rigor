# Issue #2488 — a writer a class gains from a call on an explicit receiver outside its body joins its census, as
# `RA.class_eval { attr_writer :x }` does. `RA` is declared in b.rb and `RB` here, with each writer call in the other
# file, so neither file order decides. Under Ruby 4.0.5 each quiet `get` returns "A" after the matching writer runs
# (`ra.w = "a"`, `ra.setv`), and each reporting one raises NoMethodError on `nil`.
RA.attr_writer :w
RA.send(:attr_writer, :y)
RA.public_send(:attr_accessor, :z)
RA.define_method(:setv) { @v = "a" }
RA.send(:define_method, :setu) { @u = "a" }
RA.class_eval { attr_writer :x }

class RB
  def initialize = (@w = nil)
  def get = @w.upcase
  def typed = assert_type("Dynamic[top]?", @w)
end

# The same calls in the file that declares the class.
class RS
  def initialize = (@w = nil; @v = nil)
  def get_w = @w.upcase
  def get_v = @v.upcase
  def typed_v = assert_type("\"a\"?", @v)
end

RS.attr_writer :w
RS.define_method(:setv) { @v = "a" }

# A writer on another class leaves this one's `@q` `nil`.
class RQ
  def initialize = (@q = nil)
  def get = @q.upcase # FIRES call.undefined-method
end

RB.attr_writer :q
