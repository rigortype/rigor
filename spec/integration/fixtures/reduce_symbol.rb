require "rigor/testing"
include Rigor::Testing

# Symbol-form `reduce` / `inject` recover a precise return type
# instead of widening to `Dynamic[top]` through the
# `Enumerable#reduce: (untyped, Symbol) -> untyped` RBS overload.

# 2-arg seed form over a constant Range[Integer] — the classic
# factorial accumulator. `:*` on Integer returns Integer; the
# precision target is the `Integer` carrier, not a constant-folded
# value.
fact = (1..5).reduce(1, :*)
assert_type("Integer", fact)

# 2-arg seed form over a Range whose end is a non-literal Integer
# (`rand` returns Integer). The Range still carries an Integer
# element type, so the fold resolves to `Integer`.
upper = rand(10)
ranged = (1..upper).reduce(1, :*)
assert_type("Integer", ranged)

# 1-arg no-seed form over a literal Integer collection. RBS models
# this overload as `() { (E, E) -> E } -> E` (no nil), so the
# result is `Integer` without a manufactured nil.
sum = [1, 2, 3].reduce(:+)
assert_type("Integer", sum)

# `inject` alias, 2-arg seed form.
sum2 = [1, 2, 3].inject(0, :+)
assert_type("Integer", sum2)

# String element type with `:+` concatenation.
joined = %w[a b].reduce(:+)
assert_type("String", joined)
