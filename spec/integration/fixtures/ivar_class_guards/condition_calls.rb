require "rigor/testing"
include Rigor::Testing

# Issue #1963 — a call inside a condition runs after the operands before it, so an instance-variable narrowing those
# operands made does not hold past a call that may write the variable: an implicit-self or `self.` call, unless the
# analysis proves it writes no such variable (#1596). Each `flag!` assigns `@x = "s"`, so under Ruby 4.0.5, with `@x`
# nil at the guard, every quiet read returns "S".
#
# The controls keep the narrowing and report where Ruby 4.0.5 raises NoMethodError on `nil`: a callee proven to write
# nothing or another variable, a call on another object, and a lambda literal, which runs nothing where it is written.
class ConditionCalls
  def initialize(peer)
    @x = nil
    @y = 0
    @peer = peer
  end

  def flag!
    @x = "s"
    true
  end

  def log(message) = warn(message)

  def pure?
    log("checked")
    true
  end

  def other_ivar!
    @y += 1
    true
  end

  def and_guard
    @x.upcase if @x.nil? && flag! # QUIET-1446
  end

  def or_guard
    if !@x.nil? || !flag!
      0
    else
      @x.upcase # QUIET-1446
    end
  end

  def ternary
    @x.nil? && flag! ? @x.upcase : 0 # QUIET-1446
  end

  def unless_guard
    @x.upcase unless @x || !flag! # QUIET-1446
  end

  def elsif_guard
    if @y > 5
      0
    elsif @x.nil? && flag!
      @x.upcase # QUIET-1446
    end
  end

  def while_guard
    while @x.nil? && flag!
      return @x.upcase # QUIET-1446
    end
  end

  def until_guard
    until !@x.nil? || !flag!
      return @x.upcase # QUIET-1446
    end
  end

  def subjectless_case
    case
    when @x.nil? && flag! then @x.upcase # QUIET-1446
    end
  end

  def block_in_operand
    @x.upcase if @x.nil? && [1].any? { flag! } # QUIET-1446
  end

  def self_receiver
    @x.upcase if @x.nil? && self.flag! # QUIET-1446
  end

  def value_position
    [(@x.nil? && flag! ? @x.upcase : 0)] # QUIET-1446
  end

  def after_the_call
    assert_type("nil", @x) if flag! && @x.nil?
  end

  def proven_pure
    @x.upcase if @x.nil? && pure? # FIRES-1446 call.undefined-method
  end

  def proven_other_ivar
    @x.upcase if @x.nil? && other_ivar! # FIRES-1446 call.undefined-method
  end

  def other_receiver
    @x.upcase if @x.nil? && @peer.flag! # FIRES-1446 call.undefined-method
  end

  def lambda_literal
    @x.upcase if @x.nil? && -> { flag! } # FIRES-1446 call.undefined-method
  end
end

class ConditionPeer
  def flag!
    @x = "p"
    true
  end
end

# Issue #1963 review — a call the proof cannot clear widens a narrowed variable back over its seed, but a `nil`
# only that widening brings back is not reported, as a declared one is not (ADR-58): the call far more often leaves
# the variable alone. Under Ruby 4.0.5 each method of `Shower.new(ShowerPeer.new)` returns "T".
class Shower
  attr_reader :items

  def initialize(peer)
    @tag = "t"
    @items = [1]
    @peer = peer
  end

  def clear_tag = (@tag = nil)
  def any_item? = items.any?
  def stored? = !@items.empty?
  def visible? = respond_to?(:items)

  def attribute_call
    if @tag && any_item?
      t = @tag
      t.upcase # QUIET-1446
    end
  end

  def proven_call
    if @tag && stored?
      t = @tag
      t.upcase # QUIET-1446
    end
  end

  def while_call
    while @tag && visible?
      t = @tag
      return t.upcase # QUIET-1446
    end
  end

  def peer_call
    if @tag && @peer.ok?
      t = @tag
      t.upcase # QUIET-1446
    end
  end

  def include_call
    if @tag && items.include?(1)
      t = @tag
      t.upcase # QUIET-1446
    end
  end
end

class ShowerPeer
  def ok? = true
end

# A narrowing that kept `nil` widens without the mark, so a read Ruby makes on `nil` still reports: under Ruby 4.0.5
# `NilTag.new.after_nil_guard` raises NoMethodError on the read.
class NilTag
  attr_reader :items

  def initialize
    @tag = nil
    @items = [1]
  end

  def name_tag = (@tag = "t")
  def ready? = items.any?

  def after_nil_guard
    if @tag.nil? && ready?
      t = @tag
      t.upcase # FIRES-1446 call.possible-nil-receiver
    end
  end
end
