require "rigor/testing"
include Rigor::Testing

# Issue #541 — an `attr_writer` / `attr_accessor` declaration is a write
# to its ivar. The class-ivar pre-pass recorded only the `@x = nil` the
# constructor makes, so a read in another method typed `nil`: `if c`
# folded always-falsey and `@cb.call` drew `undefined method for nil`,
# on a field the class itself declares assignable from outside. The
# declaration now contributes what a hand-written untyped setter
# `def cb=(v) = @cb = v` does.

# The external report, verbatim: a callback injected through the accessor
# from another file.
class Radio
  attr_accessor :cb

  def initialize = @cb = nil

  def deliver(v)
    c = @cb
    c.call(v) if c
  end
end

# A second `nil` write does not undo the declaration.
class DisarmableRadio
  attr_accessor :cb

  def initialize = @cb = nil
  def disarm = @cb = nil

  def deliver(v)
    c = @cb
    c.call(v) if c
  end
end

# The direct call on the ivar, with no guard to make the nil flow-live.
class DirectRadio
  attr_accessor :cb

  def initialize = @cb = nil
  def deliver(v) = @cb.call(v)
end

# A `false` flag, several names in one call, and a string argument.
class Flags
  attr_writer :flag, "verbose"

  def initialize
    @flag = false
    @verbose = false
  end

  def run
    assert_type("Dynamic[top] | false", @flag)
    return :flagged if @flag

    :loud if @verbose
  end
end

# `private attr_writer`, and a bare `private` above the macro.
class Hidden
  private attr_writer :sink

  private

  attr_writer :tap

  public

  def initialize
    @sink = nil
    @tap = nil
  end

  def emit(v)
    @sink&.call(v)
    :tapped if @tap
  end
end

# Controls. A reader defines no way in, so the constructor's `nil` is the
# only value the ivar ever holds.
class ReaderOnly
  attr_reader :x

  def initialize = @x = nil
  def use = (:set if @x) # GENUINE-FALSEY
  def probe = assert_type("nil", @x)
end

# No accessor at all.
class NoAccessor
  def initialize = @x = nil
  def use = (:set if @x) # GENUINE-FALSEY
end

# The singleton side's accessor writes the class object's ivar, not the
# instance's.
class SingletonAccessor
  class << self
    attr_accessor :x
  end

  def initialize = @x = nil
  def use = (:set if @x) # GENUINE-FALSEY
end

# A splatted name list is not read.
class SplatNames
  NAMES = %i[x].freeze
  attr_writer(*NAMES)

  def initialize = @x = nil
  def use = (:set if @x) # GENUINE-FALSEY
end

# The hand-written setter the declaration now matches.
class HandSetter
  def cb=(v)
    @cb = v
  end

  def initialize = @cb = nil

  def deliver(v)
    c = @cb
    c.call(v) if c
  end
end
