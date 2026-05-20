require "rigor/testing"
include Rigor::Testing

# ADR-24 slice 2 — included-module resolution. `Worker` does
# not define `boom`; the implicit-self call inside `Worker#run`
# resolves against the `Helpers` module `Worker` `include`s,
# and adopts its `bot` return. Combined with slice 3 the
# `boom(...) if x.nil?` guard then narrows the fall-through to
# the non-nil fragment of `x`.
module Helpers
  def boom(_msg)
    raise "stop"
  end
end

class Worker
  include Helpers

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
