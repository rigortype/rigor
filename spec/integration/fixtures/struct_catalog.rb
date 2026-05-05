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

# `Struct.new(...)` builds a fresh anonymous subclass at runtime.
# The catalog declines (block-dependent), but RBS-tier dispatch
# on the `Class<Struct>` receiver still resolves the call's
# return type to `Nominal[Struct]` — useful for narrowing
# downstream calls back through the catalog.
klass = Struct.new(:foo, :bar)
assert_type("Struct", klass)

# Instantiating the subclass and reading a member widens further
# — the runtime answer depends on the subclass's member list,
# which the catalog deliberately does not encode. `:[]` is
# blocklisted so even a future Constant<Struct> carrier would
# not fold it. Today the chained `.new(...)` on the anonymous
# subclass falls through to `Dynamic[top]` because the catalog
# does not model the per-subclass `Class<Subclass>` shape.
inst = Struct.new(:foo).new(1)
assert_type("Dynamic[top]", inst)
