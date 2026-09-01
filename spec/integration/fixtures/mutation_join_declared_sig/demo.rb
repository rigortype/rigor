require "rigor/testing"
include Rigor::Testing

# Issue #560, the FP side of the added-value join — the join must not
# grow a carrier past what a HAND-WRITTEN signature admits.
#
# haml's temple builders are the corpus shape. `compile_html` really
# does append `[:static, …]` pairs to an array seeded `[:multi]`, and
# its hand-written sig says `Array[:multi]`. Joining the appended tuple
# precisely reads `Array[:multi | [:static, String]]`, which the
# subtype oracle answers `:no` on — eight false
# `def.return-type-mismatch` on correct code. (PR #561 hit the same
# wall from the other direction: widening the seed's own value pinning
# under `<<` reads `Array[Symbol]`, equally rejected.)
#
# The join is admissibility-gated instead: a member whose class the
# seed does not admit contributes `Dynamic[top]`, so the carrier reads
# `Array[:multi | Dynamic[top]]` — gradual, so it ACCEPTS against the
# declared type, while still refusing to claim an element set that is
# not true.
class Temple
  # The haml shape verbatim. Must draw no return-type mismatch.
  def compile_html(node)
    temple = [:multi]
    temple << [:static, "<style>\n"]
    temple << node
    temple << [:static, "\n</style>"]
    temple
  end

  # The homogeneous sibling: every appended member IS a Symbol, so the
  # join stays precise and the declared `Array[Symbol]` still accepts.
  # Without this case the fixture could pass by never joining at all.
  def collect_flags(flag)
    flags = [:multi]
    flags << flag
    flags
  end

  # And the rule is still LIVE in this fixture: nothing mutates this
  # array, the body plainly returns integers, and the declared
  # `Array[Symbol]` must still be rejected.
  def genuinely_wrong
    [1, 2]
  end
end

# The same two carriers built at top level, where no declared signature
# absorbs the call's return type — so these pin what the join actually
# INFERS, and the method bodies above pin what the rule does with it.
heterogeneous = [:multi]
heterogeneous << [:static, "x"]
assert_type("Array[:multi | Dynamic[top]]", heterogeneous)

homogeneous = [:multi]
homogeneous << :static
assert_type("Array[:multi | Symbol]", homogeneous)
