require "rigor/testing"
include Rigor::Testing

# ADR-24 slice 3 — a branch whose inferred type is `Bot` is a
# terminating branch. `boom` is an always-diverging guard
# helper; ADR-24 slice 1 resolves the implicit-self call to a
# `bot` return. `boom if x.nil?` is therefore a terminating
# guard exactly like `raise ... if x.nil?` — even though
# `boom` is not one of the syntactic exit calls (raise / throw
# / exit / abort / fail) — so the fall-through observes `x`
# narrowed to its non-nil fragment.
def boom
  raise "stop"
end

def go(_)
  x = if rand < 0.5
    "hello"
  else
    nil
  end
  boom if x.nil?

  assert_type('"hello"', x)
  x
end
