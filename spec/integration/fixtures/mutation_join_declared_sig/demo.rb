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

  # A DECLARED gradual arm must survive the block-capture rederivation. `a`'s signature says the
  # array may hold anything, so `first.upcase` is correct code — but the slice-C rederivation joins
  # the body's stores onto the declared type, and an earlier draft of the straight-line floor-scrub
  # flattened Union members before dropping Dynamic. That could not tell a DECLARED `untyped` from
  # the floor, closed the parameter to `Array[Integer]`, and drew a false `undefined method`.
  # Provenance would tell them apart (issue #580); until then the floor is kept out of that seam at
  # its source instead, and a declared arm survives everywhere.
  def keeps_declared_gradual_arm(a)
    [1, 2].each { a.push(rand(9)) }
    a.first.upcase
  end

  # The haml wall reached through the UNREADABLE-ARG door. `nodes` is untyped, so the concat contributes
  # no element evidence — but the mutation ran, so the retained `:multi` pinning alone is not the answer
  # either. Answering `Array[Symbol]` (the seed's nominal base) closes the parameter on zero evidence and
  # draws the #561 mismatch against this method's hand-written `-> Array[:multi]`; the one-store gradual
  # arm keeps the accepting `Array[:multi | Dynamic[top]]` form instead. The `<<` sibling above covers the
  # readable-foreign-evidence path, and this covers the unreadable one.
  def compile_all(nodes)
    temple = [:multi]
    temple.concat(nodes)
    temple
  end

  # Issue #586 — the BARE declared `untyped` element, the shape the
  # `Integer | untyped` case above could not see. There the declared arm
  # sits inside a Union and a non-recursive drop leaves it alone; here the
  # seed element IS the `Dynamic`, and the rederivation dropped it the
  # moment the body's stores contributed a concrete class. `a` closed to
  # `Array[Integer]` and `a.first.upcase` — correct Ruby, the declaration
  # says the array may hold anything — drew a false `undefined method`.
  # The declared arm is a statement about what the array ALREADY holds;
  # the body's stores are evidence about what the body added. It survives.
  def keeps_declared_untyped_element(a)
    [1, 2].each { a.push(rand(9)) }
    assert_type("Array[Dynamic[top] | Integer]", a)
    a.first.upcase
  end

  # The same declared arm through the LOOP seam, which shares the join.
  def keeps_declared_untyped_element_in_loop(a)
    i = 0
    while i < 2
      a.push(rand(9))
      i += 1
    end
    assert_type("Array[Dynamic[top] | Integer]", a)
    a.first.upcase
  end

  # And the Hash twin: a declared `Hash[untyped, untyped]` keeps both
  # gradual arms however many pairs the body stores.
  def keeps_declared_untyped_hash_arms(h)
    [1, 2].each { |x| h[x] = rand(9) }
    assert_type("Hash[1 | 2 | Dynamic[top], Dynamic[top] | Integer]", h)
    h[1].upcase
  end

  # The must-still-fire siblings. A FRESH empty seed carries no arm to
  # keep, and the block / loop seams see every store in their body, so
  # the parameter rightly CLOSES to what was appended and the diagnostic
  # is right. Without these the three above would pass on a seam that had
  # simply gone gradual everywhere.
  def closes_a_fresh_seed(xs)
    acc = []
    xs.each { |x| acc.push(x.to_i) }
    assert_type("Array[Integer]", acc)
    acc.first.upcase # GENUINE-UNDEFINED
  end

  def closes_a_fresh_seed_in_loop
    acc = []
    i = 0
    while i < 2
      acc.push(rand(9))
      i += 1
    end
    assert_type("Array[Integer]", acc)
    acc.first.upcase # GENUINE-UNDEFINED
  end

  # A seed that is a `non-empty-array[String]` REFINEMENT. The seams now
  # read the seed from before the mutation widening turned it into its
  # `Array[String]` base, so they meet the refinement carrier itself; it
  # must read through to the base and keep the appended arms. Declining
  # it would hand the continuation the widened base alone — `Array[String]`
  # for an array that really holds integers too.
  def appends_into_non_empty_seed(xs)
    if xs.any?
      [1, 2].each { |y| xs << y }
      assert_type("Array[1 | 2 | String]", xs)
    end
    xs
  end

  # The loop form of the same seed. Before the seams read through the
  # refinement this read `Array[String] | non-empty-array[String]`, with
  # the appended `1` missing entirely.
  def appends_into_non_empty_seed_in_loop(xs)
    if xs.any?
      i = 0
      while i < 2
        xs << 1
        i += 1
      end
      assert_type("Array[1 | String]", xs)
    end
    xs
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
assert_type("Array[:multi | Dynamic[top] | Symbol]", homogeneous)
