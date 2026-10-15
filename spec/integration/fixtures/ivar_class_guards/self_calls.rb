require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1596 — an implicit-self or `self.` call between a class guard on an instance variable and the read keeps the
# narrowing when the analysis proves the callee writes no such variable: the method resolves to one `def` on the class
# and on every project subclass, and every method it reaches is such a `def` or a core method on a receiver the read can
# type. Under Ruby 4.0.5, with `@io` holding a `StringIO` at the guard, each quiet read returns the captured text.
#
# Each reported read follows a call the analysis cannot prove. Where the callee sets `@io` back to `STDOUT`, the read
# raises NoMethodError under Ruby 4.0.5; `PlainLocal` and `ModuleSelf` do not, and are reported because the read cannot
# type a local receiver, and because a class including the module may define the callee.
class Holder
  def initialize
    @io = STDOUT
    @count = 0
    @name = nil
  end

  def rename = (@name = "bob")
  def log(message) = warn(message)
  def count = (@count += 1)

  def report(message)
    count
    log(message)
    STDERR.puts(format("%s", message))
  end

  def tick = (@count < 3 ? tock : nil)

  def tock
    count
    tick
  end

  def implicit_self
    return unless @io.is_a?(StringIO)

    log("dumping")
    @io.string # QUIET-1446
  end

  def explicit_self
    return unless @io.is_a?(StringIO)

    self.log("dumping")
    @io.string # QUIET-1446
  end

  # `report` writes `@count` and calls `count` and `log`; `tick` and `tock` call each other.
  def transitive_other_ivar
    return unless @io.is_a?(StringIO)

    report("dumping")
    tick
    @io.string # QUIET-1446
  end

  def truthiness
    return unless @name

    log("naming")
    assert_type('"bob"', @name)
  end
end

class DirectWrite
  def initialize = (@io = STDOUT)
  def log(_message) = (@io = STDOUT)

  def dump
    return unless @io.is_a?(StringIO)

    log("dumping")
    @io.string # FIRES-1446 call.undefined-method
  end
end

class TransitiveWrite
  def initialize = (@io = STDOUT)

  def log(message)
    warn(message)
    reset
  end

  def reset = (@io = STDOUT)

  def dump
    return unless @io.is_a?(StringIO)

    log("dumping")
    @io.string # FIRES-1446 call.undefined-method
  end
end

class RecursiveWrite
  def initialize = (@io = STDOUT)
  def ping(n) = (n.positive? ? pong(n - 1) : @io = STDOUT)
  def pong(n) = ping(n)

  def dump
    return unless @io.is_a?(StringIO)

    ping(2)
    @io.string # FIRES-1446 call.undefined-method
  end
end

class Reflective
  def initialize = (@io = STDOUT)
  def reset = (@io = STDOUT)
  def literal_set = instance_variable_set(:@io, STDOUT)
  def computed_set(name = :@io) = instance_variable_set(name, STDOUT)
  def via_send = send(:reset)
  def via_public_send = public_send(:reset)
  def via_method = method(:reset).call
  def via_instance_eval = instance_eval { reset }
  def via_instance_exec = instance_exec { reset }

  define_method(:via_define_method) { @io = STDOUT }

  def literal_set_dump
    return unless @io.is_a?(StringIO)

    literal_set
    @io.string # FIRES-1446 call.undefined-method
  end

  def computed_set_dump
    return unless @io.is_a?(StringIO)

    computed_set
    @io.string # FIRES-1446 call.undefined-method
  end

  def send_dump
    return unless @io.is_a?(StringIO)

    via_send
    @io.string # FIRES-1446 call.undefined-method
  end

  def public_send_dump
    return unless @io.is_a?(StringIO)

    via_public_send
    @io.string # FIRES-1446 call.undefined-method
  end

  def method_dump
    return unless @io.is_a?(StringIO)

    via_method
    @io.string # FIRES-1446 call.undefined-method
  end

  def instance_eval_dump
    return unless @io.is_a?(StringIO)

    via_instance_eval
    @io.string # FIRES-1446 call.undefined-method
  end

  def instance_exec_dump
    return unless @io.is_a?(StringIO)

    via_instance_exec
    @io.string # FIRES-1446 call.undefined-method
  end

  def define_method_dump
    return unless @io.is_a?(StringIO)

    via_define_method
    @io.string # FIRES-1446 call.undefined-method
  end
end

# The block is the caller's code; the callee runs it.
class Yielding
  def initialize = (@io = STDOUT)
  def reset = (@io = STDOUT)
  def via_yield = yield

  def dump
    return unless @io.is_a?(StringIO)

    via_yield { reset }
    @io.string # FIRES-1446 call.undefined-method
  end
end

# `undefined_helper` resolves to no method, so `method_missing` runs.
class Missing
  def initialize = (@io = STDOUT)
  def method_missing(_name, *) = (@io = STDOUT)
  def respond_to_missing?(*) = true
  def log = undefined_helper

  def dump
    return unless @io.is_a?(StringIO)

    log
    @io.string # FIRES-1446 call.undefined-method
  end
end

class Writer
  attr_writer :io

  def initialize = (@io = STDOUT)
  def log = (self.io = STDOUT)

  def dump
    return unless @io.is_a?(StringIO)

    log
    # `attr_writer` seeds `@io` with `Dynamic`, which reports nothing; the guard's `StringIO` is restored, not kept.
    assert_type("Dynamic[top] | IO | StringIO", @io)
  end
end

# `Overridden#dump` on a `Override` calls `Override#log`.
class Overridden
  def initialize = (@io = STDOUT)
  def log = nil

  def dump
    return unless @io.is_a?(StringIO)

    log
    @io.string # FIRES-1446 call.undefined-method
  end
end

class Override < Overridden
  def log = (@io = STDOUT)
end

class DynamicOverridden
  def initialize = (@io = STDOUT)
  def log = nil

  def dump
    return unless @io.is_a?(StringIO)

    log
    @io.string # FIRES-1446 call.undefined-method
  end
end

class DynamicOverride < DynamicOverridden
  define_method(:log) { @io = STDOUT }
end

module Loud
  def log = (@io = STDOUT)
end

module Quiet
  def log = warn("dumping")
end

# A prepended `log` runs ahead of the class's own.
class Prepended
  prepend Loud

  def initialize = (@io = STDOUT)
  def log = nil

  def dump
    return unless @io.is_a?(StringIO)

    log
    @io.string # FIRES-1446 call.undefined-method
  end
end

class Included
  include Quiet

  def initialize = (@io = STDOUT)

  def dump
    return unless @io.is_a?(StringIO)

    log
    @io.string # QUIET-1446
  end
end

class SuperParent
  def initialize = (@io = STDOUT)
  def log = (@io = STDOUT)
end

class SuperChild < SuperParent
  def initialize = (@io = STDOUT)
  def log = super

  def dump
    return unless @io.is_a?(StringIO)

    log
    @io.string # FIRES-1446 call.undefined-method
  end
end

# `@poker` holds `self`, and `Poker#poke` writes back through it.
class Poker
  def initialize(holder) = (@holder = holder)
  def poke = @holder.reset
end

class OtherReceiver
  def initialize = (@io = STDOUT; @poker = Poker.new(self))
  def reset = (@io = STDOUT)
  def log = @poker.poke

  def dump
    return unless @io.is_a?(StringIO)

    log
    @io.string # FIRES-1446 call.undefined-method
  end
end

# `@me` is `self`, and `instance_variable_set` on it writes `@io`.
class AliasedSelf
  def initialize = (@io = STDOUT; @me = self)
  def log = @me.instance_variable_set(:@io, STDOUT)

  def dump
    return unless @io.is_a?(StringIO)

    log
    @io.string # FIRES-1446 call.undefined-method
  end
end

class Refined
  def initialize = (@io = STDOUT)
  def note = nil
end

module Refining
  refine Refined do
    def note = (@io = STDOUT)
  end
end

using Refining

# The refinement is in effect here, so `note` runs `Refining`'s.
class Refined
  def dump
    return unless @io.is_a?(StringIO)

    note
    @io.string # FIRES-1446 call.undefined-method
  end
end

class PlainLocal
  def initialize = (@io = STDOUT)
  def log(message) = message.to_s

  def dump
    return unless @io.is_a?(StringIO)

    log("dumping")
    @io.string # FIRES-1446 call.undefined-method
  end
end

module ModuleSelf
  def setup = (@io = STDOUT)
  def log = nil

  def dump
    return unless @io.is_a?(StringIO)

    log
    # The module's seed holds `nil` (no `initialize` writes `@io` before a read); the guard's narrowing is undone.
    assert_type("IO?", @io)
  end
end

class UsesModuleSelf
  include ModuleSelf

  def initialize = setup
end
