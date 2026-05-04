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
assert_type("false | true", r == Rational(3, 4))
assert_type("Float", r.fdiv(2))
