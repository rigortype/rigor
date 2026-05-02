require "rigor/testing"
include Rigor::Testing

# Composite refinement names that compose a point-removal half
# (`Difference[String, ""]`) with a predicate-subset half
# (`Refined[String, :lowercase]` or `:uppercase`) via
# `Type::Intersection`. The carrier prints in its kebab-case
# canonical spelling at call sites; RBS erasure folds back to
# `String`. Catalog projections delegate to whichever member
# answers first, so size-tier projections still tighten through
# the intersection.
class Slug
  def lower
    "alice"
  end

  def upper
    "ALICE"
  end
end

s = Slug.new

l = s.lower
assert_type("non-empty-lowercase-string", l)
# Size projection delegates to the non_empty_string member.
assert_type("positive-int", l.size)

u = s.upper
assert_type("non-empty-uppercase-string", u)
assert_type("positive-int", u.size)
