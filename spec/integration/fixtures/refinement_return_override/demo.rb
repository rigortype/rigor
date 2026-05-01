require "rigor/testing"
include Rigor::Testing

# `RBS::Extended` lets a sig file tighten a method's return type
# to one of the imported-built-in refinements
# (docs/type-specification/imported-built-in-types.md). The
# annotation lives in the sig file (sig/user.rbs):
#
#   class User
#     %a{rigor:v1:return: non-empty-string}
#     def name: () -> String
#   end
#
# At call sites Rigor sees the strict refinement, not the
# RBS-declared base. `non-empty-string` propagates through the
# catalog tier so `name.size` is `positive-int` and
# `name.empty?` is `Constant[false]`. The base `String` is
# preserved as the RBS erasure.
class User
  def name
    "Alice"
  end

  def age
    42
  end
end

user = User.new

n = user.name
assert_type("non-empty-string", n)
assert_type("positive-int", n.size)
assert_type("positive-int", n.length)
assert_type("false", n.empty?)

a = user.age
assert_type("positive-int", a)
assert_type("false", a.zero?)
