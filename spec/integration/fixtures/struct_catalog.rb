require "rigor/testing"
include Rigor::Testing

# ADR-48 Struct follow-up — `Struct.new` value folding (slices 1 + 2, the
# sound *transient* form). `Struct.new(:a, :b)` now carries a precise
# `StructClass` member layout, `.new(...)` materialises a `StructInstance`,
# and a member read off a **fresh** (chained) instance folds to the member
# type. Because a `Struct` instance is mutable, a read off a *stored*
# binding degrades to `Dynamic[top]` rather than fold a possibly-stale
# value (the fold-safe-local promotion is the deferred slice 3).

# `Struct.new(:a, :b)` builds a fresh anonymous Struct *subclass* (a class
# object), now carried as a `StructClass` with the ordered member list so
# the chained `.new(...)` materialises a precise instance.
klass = Struct.new(:foo, :bar)
assert_type("Struct.new(:foo, :bar)", klass)

# `.members` on the class folds to the member-name tuple.
assert_type("[:foo, :bar]", klass.members)

# Instantiating the subclass yields a `StructInstance` whose member map is
# read off the constructor arguments.
inst = Struct.new(:foo).new(1)
assert_type("Struct(foo: 1)", inst)

# Zero-/under-arg chained construction is legal — trailing members default
# to `nil` — and must not fire a wrong-arity diagnostic.
zero = Struct.new(:foo, :bar).new
assert_type("Struct(foo: nil, bar: nil)", zero)

# Headline: a member read off a FRESH instance (the transient receiver of a
# `.new(...).x` chain, which cannot have been mutated between construction
# and the read) folds to the precise member type.
assert_type("1", Struct.new(:x, :y).new(1, 2).x)
assert_type("2", Struct.new(:x, :y).new(1, 2).y)

# `keyword_init: true` constructs by name; the fold honours the form.
point = Struct.new(:x, :y, keyword_init: true)
assert_type("3", point.new(x: 3, y: 4).x)

# Projections fold off a fresh instance.
assert_type("{ x: 1, y: 2 }", Struct.new(:x, :y).new(1, 2).to_h)
assert_type("[1, 2]", Struct.new(:x, :y).new(1, 2).deconstruct)

# SOUNDNESS: a `Struct` is mutable, so a member read off a STORED binding is
# NOT folded to the construction-time value (a later `inst.foo = ...` could
# have changed it). It degrades to `Dynamic[top]`, never a stale `1`.
stored = Struct.new(:foo).new(1)
assert_type("Dynamic[top]", stored.foo)
