require "rigor/testing"
include Rigor::Testing

# Predicate-subset half of the OQ3 refinement-carrier strategy
# (docs/adr/3-type-representation.md). The annotation tightens
# `Username#slug`'s RBS-declared `String` return to the
# `lowercase-string` refinement; call sites see the precise
# carrier without a runtime check, the engine projects the
# case-normalisation pair through `Refined[String, :lowercase]`,
# and RBS erasure folds the carrier back to `String`.
#
#   class Username
#     %a{rigor:v1:return: lowercase-string}
#     def slug: () -> String
#     ...
#   end
class Username
  def slug
    "alice"
  end

  def shout
    "ALICE"
  end

  def code
    "42"
  end
end

user = Username.new

s = user.slug
assert_type("lowercase-string", s)
# `String#downcase` over a lowercase-string is idempotent so the
# carrier survives.
assert_type("lowercase-string", s.downcase)
# `String#upcase` lifts a lowercase-string to an uppercase-string.
assert_type("uppercase-string", s.upcase)
# Size-tier projections still apply through the predicate carrier.
assert_type("non-negative-int", s.size)

t = user.shout
assert_type("uppercase-string", t)
assert_type("uppercase-string", t.upcase)
assert_type("lowercase-string", t.downcase)

n = user.code
assert_type("numeric-string", n)
# Digits are case-invariant so both case folds preserve the
# numeric-string predicate.
assert_type("numeric-string", n.downcase)
assert_type("numeric-string", n.upcase)
