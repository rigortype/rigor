require "rigor/testing"
include Rigor::Testing

# Kernel module-function precision (2026-07-15 uplift). `Kernel#p` / `Kernel#pp` return their
# argument, so the engine types them as a precision-PRESERVING identity: one argument passes
# through verbatim (shapes, constants, and Dynamic alike), several come back as a Tuple, and the
# zero-arg form keeps the exact RBS `nil`. `format` / `sprintf` / `String()` constant-fold when
# every input is value-pinned; `Hash()` covers only the trivially-sound shapes.

# --- p / pp identity -------------------------------------------------------

h = { a: 1 }
assert_type("{ a: 1 }", p(h))
assert_type("{ a: 1 }", pp(h))

# One constant argument passes through as the constant itself.
assert_type("1", p(1))
assert_type('"hello"', pp("hello"))

# Several arguments come back as the Tuple of their types (`p 1, 2` returns `[1, 2]`).
assert_type("[1, 2]", p(1, 2))

# The zero-arg form stays the exact RBS nil.
assert_type("nil", p)
assert_type("nil", pp)

# A splatted argument list has no static arity — the fold declines to the RBS envelope.
xs = [1, 2]
assert_type("Dynamic[top]", p(*xs))

# --- composed with scalar-key Hash-literal shapes (branch-interaction probe) --
# The p/pp identity must pass a scalar-key HashShape through verbatim, including the
# duplicate-key last-wins resolution (`1` vs `1.0` distinct; `1.0` vs `1.00` collide).
scalar_h = { 1 => 1, 1 => 2, 1.0 => 3, 1.00 => 4 }
assert_type("{ 1 => 2, 1.0 => 4 }", scalar_h)
assert_type("{ 1 => 2, 1.0 => 4 }", p(scalar_h))
assert_type("{ 1 => 2, 1.0 => 4 }", pp(scalar_h))

# --- format / sprintf constant folding -------------------------------------

assert_type('"1"', format("%d", 1))
assert_type('"00042"', format("%05d", 42))
assert_type('"pi = 3.14"', format("pi = %.2f", 3.141592))

# A directive/argument mismatch raises at fold time, so the exact fold declines and the
# literal-string lift answers instead.
assert_type("literal-string", format("%d", "abc"))

# A non-constant (but literal-bearing) value argument keeps the pre-existing literal-string
# lift: `"ab" * 4000` exceeds the constant-fold byte cap, so it stays a literal-string carrier
# rather than a value-pinned Constant, and the exact fold declines.
name = "ab" * 4000
assert_type("literal-string", format("hello %s", name))

# --- String() constant folding ----------------------------------------------

assert_type('"42"', String(42))
assert_type('"sym"', String(:sym))
assert_type('""', String(nil))
assert_type('"1.5"', String(1.5))

# --- Hash() trivially-sound slice -------------------------------------------

assert_type("{ a: 1 }", Hash({ a: 1 }))
assert_type("{}", Hash(nil))
assert_type("{}", {})

# --- conversion constructors (pre-existing, exercised for regression) --------

assert_type("42", Integer("42"))
assert_type("255", Integer("ff", 16))
assert_type("1.5", Float("1.5"))
assert_type("(1/2)", Rational(1, 2))
assert_type("(1+2i)", Complex(1, 2))
assert_type("Array[bot]", Array(nil))
assert_type("Array[5]", Array(5))

# --- user redefinition must NOT be hijacked by the identity fold -------------

class KernelFunctionsPrinter
  def p(node)
    "printed:#{node}"
  end

  def show
    # Resolves to the user-defined `p` above, not Kernel#p — the fold declines on a discovered
    # redefinition, so the result must NOT be Constant[1].
    result = p(1)
    assert_type("Dynamic[top]", result)
  end
end
