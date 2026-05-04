require "rigor/testing"
include Rigor::Testing

# Methods unlocked by extracting the Complex catalog from
# `Init_Complex` in `references/ruby/complex.c`. Complex is a
# fully-immutable value type — every public instance method is
# either pure (`:leaf`), arithmetic with a numeric coerce
# fallback (`:leaf_when_numeric`), or routes through user code
# (`:dispatch`). v0.0.7's `Kernel#Complex` literal-lift fold
# (`KernelDispatch`) lets `Complex(re, im)` calls with constant
# numeric arguments fold to a `Constant<Complex>` carrier; once
# the receiver is constant, every catalog `:leaf` method folds
# to a precise per-call constant. `:dispatch`-classified methods
# still bail because their C bodies route through user-
# redefinable `==` / `<=>` / `to_s` etc.

c = Complex(3, 4)
assert_type("(3+4i)", c)

# Catalog-classified `:leaf` accessors fold to the cached
# components on a `Constant<Complex>` receiver.
assert_type("3", c.real)
assert_type("4", c.imaginary)
assert_type("4", c.imag)
assert_type("5.0", c.abs)
assert_type("(3-4i)", c.conjugate)
assert_type("1", c.denominator)

# `Complex#real?` carries an RBS sig of `() -> false`. The
# catalog still folds to that exact value on a constant
# receiver.
assert_type("false", c.real?)

# Tuple-returning leaves. `rect` / `rectangular` return Array
# results — `foldable_constant_value?` rejects Array values, so
# the constant-fold tier declines and the RBS tier answers with
# the structural `[Numeric, Numeric]` shape. A future slice
# that lifts Array results to `Tuple[…]` (similar to the v0.0.7
# `Range#to_a` lift) would tighten these to `[3, 4]`.
assert_type("[Numeric, Numeric]", c.rect)
assert_type("[Numeric, Numeric]", c.rectangular)

# Singleton constructors. `Complex.rect` and `Complex.polar`
# are catalog-classified `:leaf` against `nucomp_s_new` /
# `nucomp_s_polar`. v0.0.7's Kernel-call lift only catches the
# `Complex(re, im)` global form; the singleton route still
# returns `Nominal[Complex]` and the subsequent accessor uses
# the RBS-tier projection. (A future slice that lifts
# constant-shaped singleton constructors would tighten this.)
assert_type("Numeric", Complex.rect(3, 4).real)
assert_type("[Complex, Complex]", Complex.polar(1, 0).coerce(Complex(1, 0)))

# Catalog-classified `:dispatch` methods MUST NOT fold even
# when the receiver is `Constant<Complex>` — their C bodies
# route through user-redefinable `==` / `<=>` / `to_s`, so the
# analyzer conservatively bails to the RBS-tier answer.
assert_type("Integer | nil", c <=> Complex(1, 1))
assert_type("String", c.to_s)
assert_type("String", c.inspect)
