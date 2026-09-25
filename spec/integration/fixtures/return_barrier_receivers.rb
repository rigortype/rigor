require "rigor/testing"
include Rigor::Testing

# A `return` inside a `define_method` / `define_singleton_method` block returns from the method the block
# defines, whatever object receives the call, and so does one inside a `lambda` block. Neither joins the
# enclosing method's return type; a `return` in an ordinary block does (issue #1382).
class Registrar
  def on(klass)
    klass.define_method(:x) { return 1 }
    "end"
  end

  def on_singleton(mod)
    mod.define_singleton_method(:y) { return 2 }
    "end"
  end

  def on_sent(klass)
    klass.public_send(:define_method, :z) { return 3 }
    "end"
  end

  def via_kernel
    Kernel.lambda { return 4 }
    "end"
  end

  def early(flag)
    [1].each { return nil if flag }
    "end"
  end
end

assert_type('"end"', Registrar.new.on(Class.new))
assert_type('"end"', Registrar.new.on_singleton(Module.new))
assert_type('"end"', Registrar.new.on_sent(Class.new))
assert_type('"end"', Registrar.new.via_kernel)
assert_type('"end"?', Registrar.new.early(true))
