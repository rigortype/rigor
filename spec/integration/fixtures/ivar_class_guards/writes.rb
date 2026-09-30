require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1446 — a write to an instance variable ends a class guard's narrowing of it: what the variable reads after a
# later call that may rebind it is the written type, not a union with the binding the guard narrowed. A plain write, a
# compound write, a multiple assignment, a `for` index and a `rescue` reference each write it.
class Poker
  def initialize(holder) = (@holder = holder)
  def poke = @holder.touch
end

class Writer
  def initialize
    @io = ARGV.empty? ? StringIO.new : STDOUT
    @poker = Poker.new(self)
  end

  def touch = nil

  def after_write
    return unless @io.is_a?(StringIO)

    @io = StringIO.new
    @poker.poke
    assert_type("StringIO", @io)
  end

  def after_or_write
    return unless @io.is_a?(StringIO)

    @io ||= StringIO.new
    @poker.poke
    assert_type("StringIO", @io)
  end

  def after_multiple_assignment
    return unless @io.is_a?(StringIO)

    @io, = StringIO.new, 1
    @poker.poke
    assert_type("StringIO", @io)
  end

  # `for @io in xs` writes `@io` on each iteration (Ruby: File::Stat under `STDOUT`).
  def after_for_index
    return unless @io.is_a?(StringIO)

    for @io in [STDOUT]; end
    @io.stat # QUIET-1446
  end

  # `rescue => @io` writes the rescued exception to `@io` (Ruby: NoMethodError, `string` on an ArgumentError).
  def after_rescue_reference
    return unless @io.is_a?(StringIO)

    begin
      Integer("x")
    rescue ArgumentError => @io
      @io.string # FIRES-1446 call.undefined-method
    end
  end

  # A branch joins with the guard's record kept, so a later call that may rebind still restores it to the binding the
  # guard narrowed (the class's seed, which the `||=` above makes nilable).
  def restored_after_join
    return unless @io.is_a?(StringIO)

    if ARGV.empty?
      n = 1
    else
      n = 2
    end
    @poker.poke
    assert_type("IO | StringIO | nil", @io)
    n
  end
end

# The same `for` index on a global ends a guard's narrowing of it (#1429).
$out = STDOUT
$out = StringIO.new if ARGV.empty?

def global_for_index
  return unless $out.is_a?(StringIO)

  for $out in [STDOUT]; end
  $out.stat # QUIET-1446
end

def global_rescue_reference
  return unless $out.is_a?(StringIO)

  begin
    Integer("x")
  rescue ArgumentError => $out
    $out.string # FIRES-1446 call.undefined-method
  end
end
