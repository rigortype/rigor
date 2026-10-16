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
