require "rigor/testing"
include Rigor::Testing

# ADR-24 slice 1 — implicit-self method-call resolution.
# A call written with no explicit receiver, inside a method
# body, now resolves against the file's top-level defs and
# the enclosing class's own definitions. Before slice 1
# every such call typed `Dynamic[top]` — the body never saw
# the callee's return type.
#
# Slice 1 is deliberately conservative inside a class body:
# it adopts a resolved return type only when that type is
# `bot` (an always-diverging guard helper) — the case that
# can only ever enable correct flow narrowing, never a new
# false positive. Top-level call sites adopt the resolved
# return type in full.

# Top-level implicit-self resolution: `helper` resolves to
# the file-level `def helper`, so `g`'s body adopts its
# `Constant[7]` return rather than `Dynamic[top]`.
def helper
  7
end

def g
  s = helper
  assert_type("7", s)
  s
end

class Calc
  # An always-diverging same-class guard helper. Its body
  # raises, so the engine infers a `bot` return.
  def boom
    raise "x"
  end

  # `boom` is an implicit-self call resolving to `Calc#boom`;
  # the call site adopts its `bot` return type.
  def use_boom
    v = boom
    assert_type("bot", v)
    v
  end
end
