require "rigor/testing"
include Rigor::Testing

# Methods unlocked by extracting the Rational catalog from
# `Init_Rational` in `references/ruby/rational.c`. Rational has
# no `rational.rb` prelude — every method is C-defined. There is
# no `Rational` literal AST node either, so a `Rational(3, 4)`
# call expression types as `Nominal[Rational]` rather than a
# `Constant<Rational>` carrier; the catalog wiring therefore
# governs the RBS-tier dispatch hop on `Nominal[Rational]`
# receivers and the (defensive) blocklist coverage. A future
# slice that adds a Rational literal AST node or a fold path for
# the `Rational(numer, denom)` Kernel call would let these same
# entries promote to `Constant<Rational>` answers without any
# catalog change.

r = Rational(3, 4)
assert_type("Rational", r)

# Catalog `:leaf` readers — RBS-declared `Integer`. The C bodies
# (`nurat_numerator`, `nurat_denominator`) read the receiver's
# struct slots and return the cached numerator / denominator;
# safe to fold the moment a `Constant<Rational>` carrier exists.
# Today the receiver is `Nominal[Rational]`, so the RBS tier
# answers `Integer`.
assert_type("Integer", r.numerator)
assert_type("Integer", r.denominator)

# Catalog `:leaf` predicates — RBS-declared `bool`. `nurat_*_p`
# inspect the numerator's sign without dispatch.
assert_type("false | true", r.positive?)
assert_type("false | true", r.negative?)

# `:leaf_when_numeric` arithmetic. `rb_rational_plus` falls
# through to `rb_num_coerce_bin` only when the operand is
# non-numeric; the catalog still accepts it under the
# `leaf_when_numeric` purity. The chained call below exercises
# the RBS tier's overload selection (`(Numeric) -> Rational`).
assert_type("Rational", r + Rational(1, 2))
assert_type("Rational", r.abs)

# Conversions — different leaf returns each.
assert_type("String", r.to_s)
assert_type("Integer", r.to_i)
assert_type("Float", r.to_f)
assert_type("Rational", r.to_r)

# Spaceship returns `Integer` for the `(Integer | Rational)`
# overload (the catalog's RBS list keeps the `Integer?` overload
# behind `(untyped)`, so a same-class comparand resolves to the
# precise `Integer` arm).
assert_type("Integer", r <=> Rational(1, 2))

# `:dispatch`-classified methods intentionally do NOT fold —
# the C body delegates to user-redefinable code. `nurat_eqeq_p`
# routes equality through `rb_funcall(:==)` on the operands,
# `nurat_fdiv` calls back into `rb_Float()`. The fold tier bails
# and the RBS tier answers with the declared return type.
assert_type("false | true", r == Rational(3, 4))
assert_type("Float", r.fdiv(2))
