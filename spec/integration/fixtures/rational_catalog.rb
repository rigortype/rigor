require "rigor/testing"
include Rigor::Testing

# Methods unlocked by extracting the Rational catalog from
# `Init_Rational` in `references/ruby/rational.c`. v0.0.7's
# `Kernel#Rational` literal-lift fold (`KernelDispatch`) lets a
# `Rational(numer, denom)` call with constant numeric arguments
# fold to a `Constant<Rational>` carrier; once the receiver is
# constant, every catalog `:leaf` / `:leaf_when_numeric` method
# folds to a precise per-call constant. Methods classified
# `:dispatch` still bail because they delegate into user-
# redefinable code at runtime.

r = Rational(3, 4)
assert_type("(3/4)", r)

# Catalog `:leaf` readers fold to the cached numerator /
# denominator constants on a `Constant<Rational>` receiver.
assert_type("3", r.numerator)
assert_type("4", r.denominator)

# Catalog `:leaf` predicates fold to a precise truthy / falsey
# constant.
assert_type("true", r.positive?)
assert_type("false", r.negative?)

# `:leaf_when_numeric` arithmetic. The fold runs `Rational#+` /
# `Rational#abs` against the receiver and folds to the resulting
# Rational constant.
assert_type("(5/4)", r + Rational(1, 2))
assert_type("(3/4)", r.abs)

# Conversions — different leaf returns each, all foldable now
# that the receiver is constant.
assert_type('"3/4"', r.to_s)
assert_type("0", r.to_i)
assert_type("0.75", r.to_f)
assert_type("(3/4)", r.to_r)

# Spaceship folds to the concrete Integer comparison result.
assert_type("1", r <=> Rational(1, 2))

# `:dispatch`-classified methods intentionally do NOT fold —
# the C body delegates to user-redefinable code. `nurat_eqeq_p`
# routes equality through `rb_funcall(:==)` on the operands,
# `nurat_fdiv` calls back into `rb_Float()`. The fold tier bails
# and the RBS tier answers with the declared return type.
assert_type("bool", r == Rational(3, 4))
# `fdiv` is now folded through RATIONAL_BINARY — returns the actual Float.
assert_type("0.375", r.fdiv(2))

# Tier A unary additions — methods now folded through RATIONAL_UNARY.
# `zero?` / `integer?` fold to a precise `Constant[bool]`.
# Note: Rational#integer? returns false for all Rationals (it checks
# `is_a?(Integer)`, not denominator == 1).
assert_type("false", r.zero?)
assert_type("true", Rational(0, 1).zero?)
assert_type("false", r.integer?)
assert_type("false", Rational(4, 1).integer?)

# `real` returns self; `abs2` returns self * self.
assert_type("(3/4)", r.real)
assert_type("(9/16)", r.abs2)

# `conj` / `conjugate` return self for real numbers.
assert_type("(3/4)", r.conj)
assert_type("(3/4)", r.conjugate)

# `nonzero?` returns self or nil.
assert_type("(3/4)", r.nonzero?)
assert_type("nil", Rational(0, 1).nonzero?)

# Tier A binary additions — folded through RATIONAL_BINARY.
# `div` performs integer floor division.
assert_type("0", r.div(2))
# `modulo` / `%` / `remainder` return Rational.
assert_type("(3/4)", r.modulo(2))
assert_type("(3/4)", r % 2)
assert_type("(3/4)", r.remainder(2))
# `fdiv` returns a Float.
assert_type("0.375", r.fdiv(2))

# Tier A tuple-lift extensions — `rect` / `rectangular` / `polar`
# lifted through NUMERIC_ARRAY_UNARY_METHODS (shared with Complex).
# `r.rect` returns `[self, 0]` (real = self, imag = 0).
assert_type("[(3/4), 0]", r.rect)
assert_type("[(3/4), 0]", r.rectangular)
assert_type("[(3/4), 0]", r.polar)
