require "rigor/testing"
include Rigor::Testing

# ADR-24 slice 2 — superclass-chain resolution. `Sub` does not
# define `boom`; the implicit-self call inside `Sub#run`
# resolves against the superclass `Base#boom`, an always-
# diverging guard helper, and adopts its `bot` return.
# Combined with slice 3 (`bot`-branch flow narrowing) the
# `boom(...) if x.nil?` guard then narrows the fall-through to
# the non-nil fragment of `x`.
class Base
  def boom(_msg)
    raise "stop"
  end
end

class Sub < Base
  def run(_)
    x = if rand < 0.5
      "hello"
    else
      nil
    end
    boom("nil") if x.nil?

    assert_type('"hello"', x)
    x
  end
end
