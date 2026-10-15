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
  def refined_note = nil
end

module Refining
  refine Refined do
    def refined_note = (@io = STDOUT)
  end
end

using Refining

# The refinement is in effect here, so `refined_note` runs `Refining`'s.
class Refined
  def dump
    return unless @io.is_a?(StringIO)

    refined_note
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

# Issue #1596 — a helper that hands `self` on as a value lets Ruby run `self`'s `to_s`, `===` or `to_ary`, which
# memoises `@label`, so each read after `@label = nil` and the helper returns the label under Ruby 4.0.5. A plain
# assignment's narrowing survives a helper proven not to write the variable, so without the `self` rule each read
# would report a nil receiver.
class Labelled
  def initialize = (@name = "n"; @label = nil)
  def to_s = (@label ||= "node:#{@name}")
  def ===(_other) = to_s
  def to_ary = [to_s, 1]
  def interpolated = warn("visiting #{self}")
  def formatted = warn(format("%s", self))
  def joined = warn([self].join)
  def displayed = display
  def compared = (case 1 when self then 1 end)
  def destructured = (first, = self; first)

  def interpolated_dump
    @label = nil
    interpolated
    @label.upcase # QUIET-1446
  end

  def formatted_dump
    @label = nil
    formatted
    @label.upcase # QUIET-1446
  end

  def joined_dump
    @label = nil
    joined
    @label.upcase # QUIET-1446
  end

  def displayed_dump
    @label = nil
    displayed
    @label.upcase # QUIET-1446
  end

  def compared_dump
    @label = nil
    compared
    @label.upcase # QUIET-1446
  end

  def destructured_dump
    @label = nil
    destructured
    @label.upcase # QUIET-1446
  end
end

# A plain assignment's narrowing now survives a helper proven to write nothing: `@label` is still nil at the read,
# which raises NoMethodError under Ruby 4.0.5.
class AssignedFold
  def initialize = (@label = "set")
  def remark = warn("noting")

  def dump
    @label = nil
    remark
    @label.upcase # FIRES-1446 call.undefined-method
  end
end

# Issue #1596 — a callee the project defines again elsewhere, by a reopening, a `class_eval` body or a
# `define_method` in any spelling: Ruby runs the later definition, which writes `@v`, so each read returns "X"
# under Ruby 4.0.5. The table holds one `def`, so the proof gives up rather than read it.
class ReopenedDef
  def initialize = (@v = "a")
  def log = nil

  def dump
    @v = nil
    log
    @v.upcase # QUIET-1446
  end
end

class ReopenedDef
  def log = (@v = "x")
end

class ClassEvalDef
  def initialize = (@v = "a")
  def log = nil

  def dump
    @v = nil
    log
    @v.upcase # QUIET-1446
  end
end

ClassEvalDef.class_eval { def log = (@v = "x") }

class ClassEvalDefineMethod
  def initialize = (@v = "a")
  def log = nil

  def dump
    @v = nil
    log
    @v.upcase # QUIET-1446
  end
end

ClassEvalDefineMethod.class_eval { define_method(:log) { @v = "x" } }

class ReopenedDefineMethod
  def initialize = (@v = "a")
  def log = nil

  def dump
    @v = nil
    log
    @v.upcase # QUIET-1446
  end
end

class ReopenedDefineMethod
  define_method(:log) { @v = "x" }
end

class SentDefineMethod
  def initialize = (@v = "a")
  def log = nil

  def dump
    @v = nil
    log
    @v.upcase # QUIET-1446
  end
end

SentDefineMethod.send(:define_method, :log) { @v = "x" }

class PublicDefineMethod
  def initialize = (@v = "a")
  def log = nil

  def dump
    @v = nil
    log
    @v.upcase # QUIET-1446
  end
end

PublicDefineMethod.define_method(:log) { @v = "x" }

class ReopenedHelper
  def initialize = (@v = "a")
  def log = note
  def note = nil

  def dump
    @v = nil
    log
    @v.upcase # QUIET-1446
  end
end

class ReopenedHelper
  def note = (@v = "x")
end

class AliasMethodCallee
  def initialize = (@v = "a")
  def assign = (@v = "x")
  def log = nil

  def dump
    @v = nil
    log
    @v.upcase # QUIET-1446
  end
end

AliasMethodCallee.alias_method(:log, :assign)

class AliasCallee
  def initialize = (@v = "a")
  def assign = (@v = "x")
  def log = nil

  def dump
    @v = nil
    log
    @v.upcase # QUIET-1446
  end
end

class AliasCallee
  alias log assign
end

# The proof does not read past an external ancestor ahead of the definer, which a signature or gem may answer the name
# from, nor past a mixin the tables cannot name. Neither callee here writes `@io`, so Ruby 4.0.5 returns the text; the
# reads are reported because the proof cannot tell.
class ExternalBase
  def log = nil
end

class ExternalAhead < ExternalBase
  include Comparable

  def initialize = (@io = STDOUT)

  def dump
    return unless @io.is_a?(StringIO)

    log
    @io.string # FIRES-1446 call.undefined-method
  end
end

class UnnamedMixin
  include(Module.new)

  def initialize = (@io = STDOUT)
  def log = nil

  def dump
    return unless @io.is_a?(StringIO)

    log
    @io.string # FIRES-1446 call.undefined-method
  end
end

# `+` on a project object runs project code: `Tally#+` resets the holder it was given.
class Tally
  def initialize(holder) = (@holder = holder)
  def +(_other) = (@holder.reset; self)
end

class OperatorWrite
  def initialize = (@io = STDOUT; @tally = Tally.new(self))
  def reset = (@io = STDOUT)
  def log = (@tally += 1)

  def dump
    return unless @io.is_a?(StringIO)

    log
    @io.string # FIRES-1446 call.undefined-method
  end
end

# A default value runs when the call leaves the parameter out.
class DefaultArgument
  def initialize = (@io = STDOUT)
  def reset = (@io = STDOUT)
  def log(_level = reset) = nil

  def dump
    return unless @io.is_a?(StringIO)

    log
    @io.string # FIRES-1446 call.undefined-method
  end
end

# `Random` in `log` is the project's `App::Random`, whose constructor resets the holder; the compact `App::Clash` header
# resolves the same name to the core class, so a core-named constant receiver the project also declares proves nothing.
module App
  class Random
    def initialize = $clash.reset
  end

  class Clash
    def initialize = (@io = STDOUT; $clash = self)
    def reset = (@io = STDOUT)
    def log = Random.new
  end
end

class App::Clash
  def dump
    return unless @io.is_a?(StringIO)

    log
    @io.string # FIRES-1446 call.undefined-method
  end
end
