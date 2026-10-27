require "rigor/testing"
include Rigor::Testing

# Issue #2039 — a statement call between a nil guard and the read widens the narrowed instance variable back over its
# class-ivar seed (#1596). Where the call's write set is unproven, the widened binding takes the declaration mark, as a
# condition's call does (#1963), so a `nil` only the seed brings back (`clear_tag`) does not report. Under Ruby 4.0.5,
# after `Shower.new`, every quiet read returns "T".
#
# The controls report where Ruby 4.0.5 raises NoMethodError on `nil`: a callee proven to write `@tag` (`clear_tag`)
# widens unmarked, and so does a narrowing that kept `nil` (`return if @tag`).
class Shower
  attr_reader :items

  def initialize
    @tag = "t"
    @items = []
  end

  def clear_tag = (@tag = nil)
  def v2? = items.any?
  def pure = 1

  def plain_call
    return unless @tag

    v2?
    t = @tag
    t.upcase # QUIET-1446
  end

  def self_dot_call
    return unless @tag

    v2?
    t = @tag
    t.upcase # QUIET-1446
  end

  def attr_reader_call
    return unless @tag

    items
    t = @tag
    t.upcase # QUIET-1446
  end

  # Guard: quiet before #2039 too, through the operand reset `!` takes.
  def negated_call
    return unless @tag

    v2?
    t = @tag
    t.upcase # QUIET-1446
  end

  def core_predicate_call
    return unless @tag

    respond_to?(:x)
    t = @tag
    t.upcase # QUIET-1446
  end

  # Guard: `pure` is proven to write nothing, so `@tag` keeps its narrowing.
  def proven_pure_call
    return unless @tag

    pure
    t = @tag
    t.upcase # QUIET-1446
  end

  # Ruby 4.0.5 raises NoMethodError: `clear_tag` is proven to write `@tag`.
  def proven_writer_call
    return unless @tag

    clear_tag
    t = @tag
    t.upcase # FIRES-1446 call.possible-nil-receiver
  end

  # Guard: Ruby 4.0.5 raises NoMethodError once `@tag` is nil: the narrowing kept `nil`.
  def nil_kept_narrowing
    return if @tag

    v2?
    t = @tag
    t.upcase # FIRES-1446 call.possible-nil-receiver
  end
end
