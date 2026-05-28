require "rigor/testing"
include Rigor::Testing

# Worked-site shape from Redmine 6.1.2
# `Redmine::Views::Builders::Structure` (ROADMAP § Future cycles
# / Type-language / engine — "Tuple / HashShape widening for
# ivar-seeded literals after mutation"). The class-ivar pre-pass
# seeds `@struct` from `@struct = [{}]` as `Tuple[Constant[{}]]`,
# then any OTHER method body's `<<` / `pop` / `push` against
# `@struct` widens that class-wide seed to
# `Nominal[Array, [untyped]]` — element precision is dropped
# because post-mutation contents are statically unknown across
# method boundaries.
class Builder
  def initialize
    @struct = [{}]
  end

  # Mutator on `@struct` — observed by the class-ivar pre-pass
  # and triggers the cross-method widening.
  def array_open
    @struct << []
  end

  # In an OTHER method body, `@struct` enters seeded by the
  # WIDENED class-ivar entry (`Array[untyped]`) — NOT the
  # seed-write's `Tuple[Constant[{}]]`. So `@struct.last`
  # resolves through the widened-element typing, the dispatcher
  # delegates the call on `Dynamic[top]`, and downstream code
  # does NOT false-fire `undefined method '<<' for {}`.
  def dispatch(key)
    if @struct.last.is_a?(::Array)
      @struct.last << key
    else
      @struct.last[key] = :v
    end
  end
end

# Hash sibling — `@bag = {a: 1}` widens to `Nominal[Hash,
# [untyped, untyped]]` once any method mutates `@bag`. Same
# soundness argument; same precision trade.
class Bag
  def initialize
    @bag = { a: 1 }
  end

  def add(k, v)
    @bag[k] = v
  end

  def read(k)
    @bag[k]
  end
end
