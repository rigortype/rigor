require "rigor/testing"
include Rigor::Testing

# Symbol-form `reduce` / `inject` recover a precise return type
# instead of widening to `Dynamic[top]` through the
# `Enumerable#reduce: (untyped, Symbol) -> untyped` RBS overload.

# 2-arg seed form over a Range whose bound is a NON-constant Integer
# (`rand` returns Integer). The Range carries an Integer element type
# but never folds to a `Constant[Range]`, so the constant-reduce tier
# declines and the symbol-form carrier tier answers `Integer` — the
# precision target here is the carrier, not a constant value. (The
# fully-constant `(1..5).reduce(1, :*) → 120` shape lives in
# `constant_reduce_fold.rb`.)
lower = rand(3)
upper = rand(10)
ranged = (lower..upper).reduce(1, :*)
assert_type("Integer", ranged)

# 1-arg no-seed form over an Integer collection built from non-constant
# elements. RBS models this overload as `() { (E, E) -> E } -> E` (no
# nil), so the result is `Integer` without a manufactured nil.
xs = [rand(10), rand(10), rand(10)]
sum = xs.reduce(:+)
assert_type("Integer", sum)

# `inject` alias, 2-arg seed form.
sum2 = xs.inject(0, :+)
assert_type("Integer", sum2)

# String element type with `:+` concatenation.
strs = [rand.to_s, rand.to_s]
joined = strs.reduce(:+)
assert_type("String", joined)
