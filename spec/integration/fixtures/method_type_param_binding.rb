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

# An untyped value is no evidence; feeding it to the identity signature must leave `T` unbound rather
# than dress the absence of evidence up as an inference.
untyped = Marshal.load("")
assert_type("Dynamic[top]", untyped)
assert_type("Dynamic[top]", Ractor.make_shareable(untyped))

# A splatted `p` has no static arity, so every arm some count of the splat reaches joins (#1801), and the
# identity signature passes that `Dynamic` through as it is.
xs = [1, 2]
dyn = p(*xs)
assert_type("Dynamic[Array[Dynamic[top]] | Dynamic[top] | nil]", dyn)
assert_type("Dynamic[Array[Dynamic[top]] | Dynamic[top] | nil]", Ractor.make_shareable(dyn))
