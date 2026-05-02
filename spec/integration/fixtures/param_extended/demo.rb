require "rigor/testing"
include Rigor::Testing

# `RBS::Extended` `rigor:v1:param: <name> <refinement>` tightens
# a method's RBS-declared parameter type. The override applies on
# both sides of the boundary:
#
# - Call site: argument-type-mismatch sees the override, so a
#   too-wide call site is flagged.
# - Body side: MethodParameterBinder also reads the override, so
#   the method body sees the tighter parameter type during
#   inference. `assert_type` calls inside the body fail unless
#   the binder honoured the directive.
#
#   class Normaliser
#     %a{rigor:v1:param: id is non-empty-string}
#     def normalise: (::String id) -> String
#   end
class Normaliser
  def normalise(id)
    # Body-side: the binder must apply the override so `id` is
    # bound to `non-empty-string`, not the RBS-declared `String`.
    assert_type("non-empty-string", id)
    # Carrier survives projections inside the body — `#size`
    # tightens to `positive-int` through the empty-removal
    # witness on the Difference carrier.
    assert_type("positive-int", id.size)
    id.upcase
  end
end

n = Normaliser.new

# Call site (OK): `"hello"` is a non-empty Constant<String> the
# refinement accepts at construction time.
n.normalise("hello")

# Call site (mismatch): literal "" fails the non-empty-string
# predicate. The argument-type-mismatch rule fires; the
# suppression-comment marks the line so the integration test
# proves both that the rule fired AND that the line matches.
n.normalise("") # rigor:disable argument-type-mismatch
