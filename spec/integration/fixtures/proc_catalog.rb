require "rigor/testing"
include Rigor::Testing

# Proc / Method / UnboundMethod catalog import. The three
# callable carriers come together because `Init_Proc` registers
# them in a single C init block. They share the same
# fundamental hazard at the catalog tier: their public methods
# invoke the wrapped Ruby code, so folding `:call` / `:[]` /
# `:===` / `:yield` would leak arbitrary user code through the
# analyzer. What the import buys us:
#
# 1. `Proc.new { … }` resolves to `Nominal[Proc]`;
#    `obj.method(:m)` to `Nominal[Method]`;
#    `Mod.instance_method(:m)` to `Nominal[UnboundMethod]`.
# 2. Reflective leaf methods (`#arity`, `#owner`, `#name`,
#    `#receiver`, `#parameters`, …) resolve through the RBS
#    tier against the recorded receiver class.
# 3. The blocklist defends `:call` / `:[]` / `:===` / `:yield` /
#    `:curry` / `:<<` / `:>>` / `:bind` / `:bind_call` /
#    `:to_proc` so a hypothetical future `Constant<Proc>` /
#    `Constant<Method>` / `Constant<UnboundMethod>` carrier
#    cannot fold a user-code-executing or identity-allocating
#    call through the catalog.

# Proc — receiver class registered through the catalog.
prc = Proc.new { 1 }
assert_type("Proc", prc)
# Reflective readers route through RBS — `#arity` returns Integer.
assert_type("Integer", prc.arity)
# `#lambda?` returns true / false per RBS — the carrier widens
# to the explicit `false | true` union (the analyzer keeps the
# disjunction rather than collapsing to the `bool` alias).
assert_type("false | true", prc.lambda?)

# Method — `Integer#method(:+)` returns a `Method` instance
# bound to the receiver. The RBS sig for `Object#method` is
# parameterised on the receiver type; here we just check the
# carrier resolves.
m = 5.method(:+)
assert_type("Method", m)
# `#owner` on Method returns the `Module` / `Class` that
# defined the method. RBS exposes this as `Class | Module`.
assert_type("Class | Module", m.owner)
# `#name` returns the symbol the method was defined under.
assert_type("Symbol", m.name)
# `#arity` is a leaf reflective reader.
assert_type("Integer", m.arity)

# UnboundMethod — `Module#instance_method` is the canonical
# constructor. Reflective readers project the same way as on
# `Method`.
um = Integer.instance_method(:+)
assert_type("UnboundMethod", um)
assert_type("Class | Module", um.owner)
assert_type("Symbol", um.name)
