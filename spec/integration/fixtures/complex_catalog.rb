require "rigor/testing"
include Rigor::Testing

# Methods unlocked by extracting the Complex catalog from
# `Init_Complex` in `references/ruby/complex.c`. Complex is a
# fully-immutable value type — every public instance method is
# either pure (`:leaf`), arithmetic with a numeric coerce
# fallback (`:leaf_when_numeric`), or routes through user code
# (`:dispatch`). There is no `Constant<Complex>` literal source
# in Rigor today (no `Prism::ImaginaryNode` -> Constant lift, no
# `Complex(...)` Kernel-call constant fold), so the catalog
# wiring mostly governs the dispatch hop on `Nominal[Complex]`
# receivers and the blocklist coverage; the assertions below
# document the RBS-tier projections the catalog accepts without
# silently inventing an unsound `Constant<Complex>` carrier.

c = Complex(3, 4)
assert_type("Complex", c)

# Catalog-classified `:leaf` accessors. Each cfunc is pure (no
# dispatch / mutation / yield), so a future `Constant<Complex>`
# carrier would fold them; today the answer comes from the RBS
# tier on a `Nominal[Complex]` receiver.
assert_type("Numeric", c.real)
assert_type("Numeric", c.imaginary)
assert_type("Numeric", c.imag)
assert_type("Numeric", c.abs)
assert_type("Complex", c.conjugate)
assert_type("Integer", c.denominator)

# `Complex#real?` carries an RBS sig of `() -> false` — a
# Constant-tier answer harvested directly from the RBS sigs the
# extractor recorded. This is the only Complex method whose
# return value is precise enough to fold to a literal at the
# Nominal-receiver tier.
assert_type("false", c.real?)

# Tuple-returning leaves. `rect` / `rectangular` and `polar`
# return `[Numeric, Numeric]` / `[Numeric, Float]` per the RBS
# sigs — the catalog tier preserves the structural answer.
assert_type("[Numeric, Numeric]", c.rect)
assert_type("[Numeric, Numeric]", c.rectangular)

# Singleton constructors. `Complex.rect` and `Complex.polar`
# are catalog-classified `:leaf` against `nucomp_s_new` /
# `nucomp_s_polar`; both return `Nominal[Complex]` per RBS.
# Composite chain — singleton constructor + instance accessor
# — exercises both the singleton-method route and the
# instance-method route through the new catalog in a single
# expression.
assert_type("Numeric", Complex.rect(3, 4).real)
assert_type("[Complex, Complex]", Complex.polar(1, 0).coerce(Complex(1, 0)))

# Catalog-classified `:dispatch` methods MUST NOT fold even when
# the receiver is `Constant<Complex>` (today: never; tomorrow:
# possibly) — their C bodies route through user-redefinable
# `==` / `<=>` / `to_s`, so the analyzer conservatively bails to
# the RBS-tier answer. `<=>` returns `Integer?` on Complex per
# RBS, and the union materialises as `Integer | nil`.
assert_type("Integer | nil", c <=> Complex(1, 1))
assert_type("String", c.to_s)
assert_type("String", c.inspect)
