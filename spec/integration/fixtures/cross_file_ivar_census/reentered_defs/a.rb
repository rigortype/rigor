# Issue #2941 — a `def` in a `class_eval`-family block whose module may be the class (or an instance's singleton
# class) defines a method that runs on an instance, so its `@x` write is the class's. Under Ruby 4.0.5 each quiet
# `get` returns "A" after `k.poke; k.set` (`k.poke(k)` for an untyped receiver), and each reporting one raises
# NoMethodError on `nil`.
class Other
end

class EvalDef
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = self.class.class_eval { def set = (@x = "a") }
end

class ExecDef
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = self.class.class_exec { def set = (@x = "a") }
end

class ModuleEvalDef
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = self.class.module_eval { def set = (@x = "a") }
end

class ModuleExecDef
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = self.class.module_exec { def set = (@x = "a") }
end

class SingletonEvalDef
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = singleton_class.class_eval { def set = (@x = "a") }
end

class OwnEvalDef
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = OwnEvalDef.class_eval { def set = (@x = "a") }
end

class ItselfEvalDef
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = itself.class.class_eval { def set = (@x = "a") }
end

# The receiver may be the class (`k.poke(k.class)`), so the write counts.
class UntypedEvalDef
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke(mod) = mod.class_eval { def set = (@x = "a") }
end

# A `def` that may not be defined still widens the entry: `k.poke(true)`.
class MayRunEvalDef
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke(flag) = (self.class.class_eval { def set = (@x = "a") } if flag)
end

# A parameter's value joins as an untyped write.
class ParamEvalDef
  def initialize = (@x = nil)
  def get = @x.upcase
  def poke = self.class.class_eval { def set(v) = (@x = v) }
end

# A sibling class of the same last name is another module: Ruby 4.0.5 raises on `get` after `k.poke;
# Ns2::Same.new.set`.
module Ns1
  class Same
    def initialize = (@x = nil)
    def get = @x.upcase # FIRES call.undefined-method
    def poke = Ns2::Same.class_eval { def set = (@x = "a") }
  end
end

module Ns2
  class Same
  end
end

# The module is provably another one, so the `def` is that module's method: Ruby 4.0.5 raises on `get` after `poke`
# and any call of `set` the new module allows.
class OtherEvalDef
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = Other.class_eval { def set = (@x = "a") }
end

class ClassNewEvalDef
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = Class.new.class_eval { def set = (@x = "a") }
end

class ClassNewEvalDefine
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = Class.new.class_eval { define_method(:set) { @x = "a" } }
end

class StructNewDef
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = Struct.new(:a) { def set = (@x = "a") }
end

class DataDefineDef
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = Data.define(:a) { def set = (@x = "a") }
end

class ModuleNewDef
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = Module.new { def set = (@x = "a") }
end

# `def self.set` in the block defines a method of the class object, whose `@x` it writes: Ruby 4.0.5 raises on `get`
# after `k.poke; k.class.set`.
class SelfDefEval
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
  def poke = self.class.class_eval { def self.set = (@x = "a") }
end

# A `class << obj` body on another class's new object or a literal defines that object's singleton methods: Ruby
# 4.0.5 raises on `get` after `poke`, and no `set` runs on an instance of the class.
class SingletonOtherNew
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method

  def poke
    class << Other.new
      define_method(:set) { @x = "a" }
    end
  end
end

class SingletonLiteral
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method

  def poke
    class << [1]
      define_method(:set) { @x = "a" }
    end
  end
end

# A new instance of the class is an instance: Ruby 4.0.5 returns "A" from `k.poke.set` read back as `get`.
class SingletonOwnNew
  def initialize = (@x = nil)
  def get = @x.upcase

  def poke
    o = SingletonOwnNew.new
    class << o
      define_method(:set) { @x = "a" }
    end
    o
  end
end

# The pokes of these classes are in b.rb.
class CrossEvalDef
  def initialize = (@x = nil)
  def get = @x.upcase
end

class CrossSingletonEvalDef
  def initialize = (@x = nil)
  def get = @x.upcase
end

class CrossOtherEvalDef
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
end

class CrossClassNewEvalDef
  def initialize = (@x = nil)
  def get = @x.upcase # FIRES call.undefined-method
end

# The `def` does not run where it is defined, so `initialize` leaves `@x` unset: Ruby 4.0.5 reads nil from
# `InitEvalDef.new.typed` and "a" after `set`.
class InitEvalDef
  def initialize = self.class.class_eval { def set = (@x = "a") }
  def typed = assert_type("\"a\"?", @x)
end
