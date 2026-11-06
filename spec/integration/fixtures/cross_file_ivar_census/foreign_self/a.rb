# Issue #2490 — a block, or a `class <<` body, inside an instance method whose `self` is provably another object
# writes that object's ivars, not the enclosing class's. Under Ruby 4.0.5 each reporting `get` raises NoMethodError on
# `nil` after `poke`, and each quiet one returns "A".
class Other
end

# Known limit: `other` may be a `EvalOther` (`k.poke(k)` returns "A" from `k.get`), so the write still counts, although
# `k.poke(Other.new)` leaves `k`'s `@x` `nil`.
class EvalOther
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke(other) = other.instance_eval { @x = "a" }
end

class EvalLiteral
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = "s".instance_eval { @x = "a" }
end

class ExecOther
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = Other.new.instance_exec { @x = "a" }
end

class ClassNew
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = Class.new { @x = "a" }
end

class StructNew
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = Struct.new(:a) { @x = "a" }
end

class DataDefine
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = Data.define(:a) { @x = "a" }
end

class ClassEval
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = self.class.class_eval { @x = "a" }
end

class SingletonBody
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke
    class << self
      @x = "a"
    end
  end
end

class DefineOther
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = Other.define_method(:set) { @x = "a" }
end

# `self`, or an object spelled as an instance of the class, is this class's instance: its `@x` is written, and
# Ruby 4.0.5 returns "A" from `get` on the instance `poke` wrote (`k.poke.get` for `EvalDup` and `EvalNew`).
class EvalSelf
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = instance_eval { @x = "a" }
end

class EvalDup
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = dup.instance_eval { @x = "a"; self }
end

class EvalNew
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = EvalNew.new.instance_eval { @x = "a"; self }
end

# A receiver that may hold an instance of the class keeps the credit: Ruby 4.0.5 returns "A" from `get` on the
# instance each `poke` wrote (`k.poke.get` for `EvalLocal` and `EvalTap`, `k.dup; k.get` for `EvalCopy`, `k.poke; k.get`
# for `EvalItself`).
class EvalLocal
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke
    o = self.class.new
    o.instance_eval { @x = "a" }
    o
  end
end

class EvalTap
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = dup.tap { |c| c.instance_eval { @x = "a" } }
end

class EvalItself
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = itself.instance_eval { @x = "a" }
end

class EvalCopy
  def initialize = (@x = nil)
  def get = @x.upcase
  def initialize_copy(src) = src.instance_eval { @x = "a" }
end

# A `define_method` whose block runs on an instance of the class counts, also nested in a barred body: Ruby 4.0.5
# returns "A" from `k.poke; k.set; k.get`.
class DefineSelfClass
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = self.class.define_method(:set) { @x = "a" }
end

class DefineOwn
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = DefineOwn.define_method(:set) { @x = "a" }
end

class EvalDefine
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = self.class.class_eval { define_method(:set) { @x = "a" } }
end

class OwnEvalDefine
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = OwnEvalDefine.class_eval { define_method(:set) { @x = "a" } }
end

class SingletonDefine
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = singleton_class.define_method(:set) { @x = "a" }
end

class SingletonBodyDefine
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke
    class << self
      define_method(:set) { @x = "a" }
    end
  end
end

# Review round 2: the reentry covers a `class_eval`-family block on `singleton_class`, a `define_method` through
# `send` / `public_send` / `__send__`, and a `class << o` body on an untyped `o` (`k.poke(k)`).
class SingletonEvalDefine
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = singleton_class.class_eval { define_method(:set) { @x = "a" } }
end

class SingletonExecDefine
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = singleton_class.class_exec { define_method(:set) { @x = "a" } }
end

class SingletonModuleEvalDefine
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = singleton_class.module_eval { define_method(:set) { @x = "a" } }
end

class SendDefine
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = self.class.class_eval { send(:define_method, :set) { @x = "a" } }
end

class PublicSendDefine
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = self.class.class_eval { public_send(:define_method, :set) { @x = "a" } }
end

class UnderscoreSendDefine
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = self.class.class_eval { __send__(:define_method, :set) { @x = "a" } }
end

class OtherSingletonBodyDefine
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke(o)
    class << o
      define_method(:set) { @x = "a" }
    end
  end
end

# A `define_method` in a `class_eval` on another class's constant runs on that class's instances: Ruby 4.0.5 raises
# on `get` after `poke`.
class OtherEvalDefine
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = Other.class_eval { define_method(:set) { @x = "a" } }
end

# An ordinary block keeps the method's `self`.
class EachBlock
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = [1].each { @x = "a" }
end

# A write in another object's block in `initialize` is no `initialize` write of this class: `@r` is unset on a new
# instance, so the read-before-write `nil` joins.
class InitPoke
  def initialize = Other.new.instance_eval { @r = "b" }
  def set = (@r = "a")
  def typed = assert_type("\"a\"?", @r)
end

# The pokes of these classes are in b.rb.
class CrossOther
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
end

class CrossSelf
  def initialize = (@x = nil)
  def get = @x.upcase
end

class CrossSingleton
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
end

class CrossUnknown
  def initialize = (@x = nil)
  def get = @x.upcase
end

class CrossEvalDefine
  def initialize = (@x = nil)
  def get = @x.upcase
end

class CrossOwnEvalDefine
  def initialize = (@x = nil)
  def get = @x.upcase
end

class CrossSingletonDefine
  def initialize = (@x = nil)
  def get = @x.upcase
end

class CrossSingletonBodyDefine
  def initialize = (@x = nil)
  def get = @x.upcase
end

class CrossSingletonEvalDefine
  def initialize = (@x = nil)
  def get = @x.upcase
end

class CrossSendDefine
  def initialize = (@x = nil)
  def get = @x.upcase
end

# A write another file makes only under a condition, in a loop or in a block widens the entry; it does not replace
# its `nil`.
class MayRun
  def initialize = (@c = nil; @l = nil; @b = nil)
  def typed_c = assert_type("String?", @c)
  def typed_l = assert_type("String?", @l)
  def typed_b = assert_type("String?", @b)
end
