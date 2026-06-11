require "rigor/testing"
include Rigor::Testing

# `Struct` is a meta-class: `Struct.new(*members)` returns a
# fresh anonymous subclass — never a `Struct` instance. Today
# Rigor never produces a `Constant<Struct>` carrier (a literal
# struct instance), so the catalog import is defensive: it
# documents the shape and forbids unsafe folds in case a future
# tier learns to lift literal struct instances into the value
# lattice.
#
# What the import buys:
#
# 1. `Struct` is a recognised receiver class — calls through it
#    route to `STRUCT_CATALOG` rather than triggering a
#    "no catalog" fall-through.
# 2. `Struct.new(...)` is catalog-classified `:block_dependent`
#    (it `rb_yield`s to the optional class-body block); the
#    fold tier declines and the result resolves through RBS
#    dispatch on the `Class<Struct>` receiver to `Nominal[Struct]`
#    rather than producing a misleading `Constant<Class>`.
# 3. The blocklist defends `:initialize_copy`, `:hash`, and
#    `:[]` so a hypothetical future `Constant<Struct>` carrier
#    cannot fold an aliasing copy, a member-dependent hash, or
#    a member-name-dependent reader through the catalog.

# `Struct.new(:a, :b)` builds a fresh anonymous Struct *subclass*
# (a class object), not a `Struct` instance. The dispatcher's
# `struct_new_lift` carries it as `Singleton[Struct]` (displayed
# `singleton(Struct)`) so the chained `.new(...)` dispatches
# instead of firing a spurious `undefined method 'new' for Struct`
# (CRuby-stdlib survey C-2 — `lib/rubygems/requirement.rb` et al.).
klass = Struct.new(:foo, :bar)
assert_type("singleton(Struct)", klass)

# Instantiating the anonymous subclass yields a `Struct` instance
# (`Nominal[Struct]`). Member-reader precision is deliberately NOT
# modelled (ADR-48 deferred Struct value folding on mutability
# grounds), so a subsequent member read widens to `Dynamic[top]`.
inst = Struct.new(:foo).new(1)
assert_type("Struct", inst)

# Zero-arg chained construction is also legal — every member
# defaults to `nil` — and must not fire a wrong-arity diagnostic
# against the real `Struct.new(*Symbol)` signature.
zero = Struct.new(:foo, :bar).new
assert_type("Struct", zero)
