require "rigor/testing"
include Rigor::Testing

# When the predicate folds to `Constant[true]` / `Constant[false]`
# the analyzer keeps only the live branch's result rather than
# joining both edges. `4.even?` is `true`, so the if-expression
# resolves to the precise `Constant[:even]` — strictly more
# informative than the `Constant[:even] | Constant[:odd]` you'd
# get if the predicate were `false | true`.
n = 4
result = if n.even?
  :even
else
  :odd
end
assert_type(":even", result)

# When the receiver type is wider (e.g. an Integer arg with no
# RBS-narrowed value) the predicate stays `false | true` and both
# branches contribute, so the result keeps the union shape.
class Parity
  def of(m)
    if m.even?
      :even
    else
      :odd
    end
  end
end

both = Parity.new.of(rand(100))
assert_type(":even | :odd", both)
