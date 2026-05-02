# `RBS::Extended` `rigor:v1:param: <name> <refinement>` tightens
# a method's RBS-declared parameter type at the call boundary.
# Argument-type-mismatch sees the override, not the underlying
# RBS type, so a too-wide call site is flagged.
#
#   class Normaliser
#     %a{rigor:v1:param: id is non-empty-string}
#     def normalise: (::String id) -> String
#   end
#
# The RBS-declared parameter is `String`; the override tightens
# it to `non-empty-string` for argument checks. A literal `""`
# argument is rejected because `non-empty-string` does not accept
# the empty string.
class Normaliser
  def normalise(id)
    id.upcase
  end
end

n = Normaliser.new

# OK call — `"hello"` is a non-empty Constant<String> the
# refinement accepts at construction time.
n.normalise("hello")

# Mismatch: literal "" fails the non-empty-string predicate.
n.normalise("") # rigor:disable argument-type-mismatch
