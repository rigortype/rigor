# Issue #2943 — def.ivar-write-mismatch compares the writes of the class's own ivar, so a write directly in a block whose
# `self` is provably another object is left out, as the class-ivar census leaves it out (#2490). Under Ruby 4.0.5
# `MismatchForeign.new.instance_variable_get(:@r)` is nil: `@r = 1` set the Other instance's ivar.
class Other
end

class MismatchForeign
  def initialize = Other.new.instance_eval { @r = 1 }
  def set = (@r = "a")
end

class MismatchClassEval
  def initialize = self.class.class_eval { @r = 1 }
  def set = (@r = "a")
end

class MismatchSingletonBody
  def initialize
    class << self
      @r = 1
    end
  end

  def set = (@r = "a")
end

class MismatchClassNew
  def initialize = Class.new { @r = 1 }
  def set = (@r = "a")
end

# A write in the class's own body, in a block that keeps `self`, or in a `define_method` block that runs on an instance
# again is the class's: both writes set the same ivar.
class MismatchOwn
  def initialize = (@r = 1)
  def set = (@r = "a") # FIRES def.ivar-write-mismatch
end

class MismatchEach
  def initialize = [1].each { @r = 1 }
  def set = (@r = "a") # FIRES def.ivar-write-mismatch
end

class MismatchReentry
  def initialize = self.class.class_eval { define_method(:put) { @r = 1 } }
  def set = (@r = "a") # FIRES def.ivar-write-mismatch
end

# A receiver that may be an instance of the class keeps the write, as the census keeps it (`MismatchUntyped.new(k)`
# writes `k`'s `@r`).
class MismatchUntyped
  def initialize(other) = other.instance_eval { @r = 1 }
  def set = (@r = "a") # FIRES def.ivar-write-mismatch
end

# The rule reads one file: b.rb's write of `@r` is compared with nothing here.
class MismatchCross
  def initialize = Other.new.instance_eval { @r = 1 }
end
