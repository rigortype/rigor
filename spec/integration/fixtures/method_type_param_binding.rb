require "rigor/testing"
include Rigor::Testing

# Issue #303 — a method-level RBS type parameter is bound from an argument position, so an identity
# signature such as `Ractor.make_shareable: [T] (T obj, copy: bool) -> T` returns the argument's own
# type instead of collapsing to `Dynamic[top]`. `Ractor` is core RBS, so this stays a flat fixture.

# --- identity binding through a positional type variable --------------------

assert_type('"x"', Ractor.make_shareable("x"))
assert_type("1", Ractor.make_shareable(1))
assert_type(":sym", Ractor.make_shareable(:sym))

# Shape carriers pass through as themselves — the binding is the argument's type object, not a
# widened nominal.
assert_type("{ a: 1 }", Ractor.make_shareable({ a: 1 }))
assert_type("[1, 2]", Ractor.make_shareable([1, 2]))

# --- no static evidence, no binding -----------------------------------------

# A splatted `p` has no static arity, so it types as `Dynamic[top]`; feeding that to the identity
# signature must leave `T` unbound rather than dress the absence of evidence up as an inference.
xs = [1, 2]
dyn = p(*xs)
assert_type("Dynamic[top]", dyn)
assert_type("Dynamic[top]", Ractor.make_shareable(dyn))
