require "rigor/testing"
include Rigor::Testing

# Stable single-hop method-chain narrowing (ROADMAP § Future
# cycles / Type-language / engine — "Method-call receiver
# narrowing across stable receivers"). After
# `if x.last.is_a?(Array)`, the dominated body's identical
# `x.last` re-reads observe the truthy-narrowed type
# `Nominal[Array]`. Without this, each `x.last` re-evaluated
# independently and the chained `<<` / `[]=` would dispatch on
# the un-narrowed (untyped / Constant / Union) receiver.
#
# Justified by the Law of Demeter at single-hop chains — re-
# evaluation soundness is strongest there. Multi-hop chains
# and chains with args / blocks lose stability for different
# reasons and are deliberately NOT recorded.

class Holder
  def initialize
    @list = [{}, []]
  end

  # `@list.last` is a single-hop chain with `:ivar` root.
  # Narrowing records `(ivar, :@list, :last) → Array` on
  # the truthy edge; the body's `@list.last << :y` then
  # dispatches against `Array` instead of the un-narrowed
  # `Hash | Array`.
  def push_last(y)
    return unless @list.last.is_a?(::Array)

    @list.last << y
  end
end

# Local-variable root receiver — same shape.
def push_last_local(xs, y)
  return unless xs.last.is_a?(Array)

  xs.last << y
end

# Class-predicate falsey edge: `if x.first.is_a?(Hash); ...;
# else; x.first.upcase; end` — the else-branch narrows the
# chain receiver to "not Hash" so `String`-shaped reads
# dispatch through `String`'s API.
def classify(xs)
  if xs.first.is_a?(Hash)
    xs.first[:key]
  else
    # No assertion here — the precision_snapshot covers it.
    xs.first
  end
end
