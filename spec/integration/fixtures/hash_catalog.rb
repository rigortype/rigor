require "rigor/testing"
include Rigor::Testing

# Methods unlocked / governed by extracting the Hash catalog from
# `Init_Hash` in `references/ruby/hash.c`. Hash literals lift to
# the dedicated `HashShape` carrier (covered by `hash_shape.rb`),
# so the catalog tier mostly governs:
#
# 1. `HashShape` size / lookup / dig — answered by the shape
#    dispatcher ahead of the catalog, but the catalog is what
#    keeps the answers from regressing once the shape opens up.
# 2. `Nominal[Hash]` size / length tightening to `non_negative_int`
#    via the size-returning-nominals tier.
# 3. The blocklist that prevents block-yielding leaves
#    (`each`, `select`, `transform_values`, `merge`, …) from
#    folding through `Constant<Hash>` carriers when the C-body
#    classifier mis-marks them as `:leaf`.

shape = { name: "Alice", age: 30 }
assert_type('{ name: "Alice", age: 30 }', shape)

# HashShape size / length — folded to a Constant via the
# shape dispatcher; the catalog tier behind it would also
# allow these because both are `:leaf` in `hash.yml`.
assert_type("2", shape.size)
assert_type("2", shape.length)

# HashShape `[]` / `fetch` / `dig` against a literal key.
assert_type('"Alice"', shape[:name])
assert_type("30", shape.fetch(:age))
assert_type('"Alice"', shape.dig(:name))

# `Nominal[Hash]` — the size projection tier returns
# `non_negative_int` regardless of the runtime contents.
def build_hash(n)
  Hash.new { |h, k| h[k] = n * k.length }
end

acc = build_hash(rand(10))
assert_type("non-negative-int", acc.size)
assert_type("non-negative-int", acc.length)

# A mutator that the YAML correctly classifies as
# `:mutates_self` (so it never folds), exercised on the
# `Nominal[Hash]` path. The fold result is the RBS-widened
# return type — the test here is that the engine does not
# crash on a Hash mutator and does not silently materialise
# a `Constant<Hash>` from it.
cleared = acc.clear
assert_type("Hash", cleared)
