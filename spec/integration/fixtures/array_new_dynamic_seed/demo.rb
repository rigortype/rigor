require "rigor/testing"
include Rigor::Testing

# Issue #615 — `Array.new` with a NON-LITERAL size answered a bare `Array`: a
# carrier with no element arm at all. The ADR-56 block and loop seams read that
# as an ELEMENTLESS seed — a fresh accumulator whose every store they saw — and
# CLOSED the carrier over the block's own stores, so a constructor that fills
# `n` slots served the type of what the block appended and nothing else.
#
# Every constructor form now seeds a real element arm, which is what puts it
# under the #586 rule that keeps every seed arm through the join.
class Grid
  # The fill form. `acc` really holds `n` `"x"`es plus the appended `1`, so
  # `acc.first.upcase` is correct Ruby. The bare-`Array` seed closed it to
  # `Array[1]` and drew `undefined method 'upcase' for 1`.
  def fill_form_survives_the_block_seam(n)
    acc = Array.new(n, "x")
    assert_type("Array[String]", acc)
    [1].each { acc.push(1) }
    assert_type("Array[1 | String]", acc)
    acc.first.upcase
  end

  # The same carrier through the LOOP seam, which shares the join.
  def fill_form_survives_the_loop_seam(n)
    acc = Array.new(n, "x")
    i = 0
    while i < 2
      acc.push(1)
      i += 1
    end
    assert_type("Array[1 | String]", acc)
    acc.first.upcase
  end

  # The no-fill form with an UNREADABLE size. `Array.new(x)` is Ruby's COPY
  # overload when its single argument is array-convertible (`Array.new([1, 2])`
  # is `[1, 2]`, not two nils), so the element cannot be claimed to be `nil`
  # here — but gradual is still an ARM, and the seam keeps it instead of
  # closing the carrier to `Array[1]`.
  def bare_form_keeps_a_gradual_arm(n)
    acc = Array.new(n)
    assert_type("Array[Dynamic[top]]", acc)
    [1].each { acc.push(1) }
    assert_type("Array[1 | Dynamic[top]]", acc)
    acc.first.upcase
  end

  # The no-fill form with a size the signature pins to `Integer`: the copy
  # overload is ruled out, so the honest element is the `nil` the constructor
  # really put in every slot.
  def sized_form_seeds_nil(n)
    acc = Array.new(n)
    assert_type("Array[nil]", acc)
    [1].each { acc.push(1) }
    assert_type("Array[1?]", acc)
    acc.first
  end

  # The block form — the algorithm-corpus shape of issue #531. The block's
  # result is the element, value-pin widened: the slots are rewritten over the
  # array's lifetime, so `Array[0]` would let a later `acc[i] == 0` fold.
  def block_form_seeds_the_block_result(n)
    acc = Array.new(n) { 0 }
    assert_type("Array[Integer]", acc)
    [1].each { acc.push("s") }
    assert_type("Array[\"s\" | Integer]", acc)
    acc.first.upcase
  end

  # The adjacency-list idiom builds `n` INDEPENDENT arrays that the program
  # then appends to, so a literal container result widens one step in too:
  # `Array[[]]` would claim every one of them stays empty.
  def block_form_widens_a_container_result(n)
    adj = Array.new(n) { [] }
    assert_type("Array[Array[Dynamic[top]]]", adj)
    adj
  end

  # And the copy overload itself must not read as a nil-filled array — this is
  # the call the `Integer`-size gate above exists for.
  def copy_overload_is_not_a_nil_fill
    a = Array.new(["x", "y"]) # rubocop:disable Style/RedundantArrayConstructor
    assert_type("Array[Dynamic[top]]", a)
    a.first.upcase
  end

  # Must-still-succeed: a small LITERAL size keeps its per-position tuple fold,
  # fill and no-fill alike.
  def literal_size_keeps_the_tuple_fold
    assert_type("[0, 0, 0]", Array.new(3, 0))
    assert_type("[nil, nil]", Array.new(2))
    assert_type("[\"s\", \"s\"]", Array.new(2) { "s" })
  end

  # Must-still-fire. A FRESH seed carries no arm to keep, the block seam saw
  # every store, and the parameter rightly CLOSES — so the diagnostic is right.
  # Without these the examples above would pass on a seam that had simply gone
  # gradual everywhere.
  def closes_a_fresh_seed(xs)
    acc = []
    xs.each { |x| acc.push(x.to_i) }
    assert_type("Array[Integer]", acc)
    acc.first.upcase # GENUINE-UNDEFINED
  end

  # `Array.new` with NO arguments really does build an empty array, so it keeps
  # the elementless carrier and closes exactly as the `[]` literal does.
  def closes_a_zero_arg_constructor(xs)
    acc = Array.new # rubocop:disable Style/EmptyLiteral
    xs.each { |x| acc.push(x.to_i) }
    assert_type("Array[Integer]", acc)
    acc.first.upcase # GENUINE-UNDEFINED
  end
end
