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

  # The same form with a size the signature pins to `Integer` reads the same
  # way. `Array.new(n)` really does put a `nil` in every slot, but a `Nominal`
  # seed gets DECLARED-carrier semantics: the join keeps a seed arm forever and
  # no whole-array rewrite retracts it, so the placeholder would become a
  # permanent nil possibility over the allocate-then-fill idiom below.
  def sized_form_stays_gradual(n)
    acc = Array.new(n)
    assert_type("Array[Dynamic[top]]", acc)
    [1].each { acc.push(1) }
    assert_type("Array[1 | Dynamic[top]]", acc)
    acc.first
  end

  # The idiom the `nil` seed cost: allocate, seed slot 0, fill from the previous
  # slot. Every line here is correct Ruby, and a `nil` element made the
  # recurrence read `undefined method '+' for nil`.
  def dp_recurrence(xs)
    n = xs.size
    dp = Array.new(n)
    dp[0] = 1
    (1...n).each { |i| dp[i] = dp[i - 1] + xs[i] }
    dp[n - 1] + 1
  end

  # The oversize-literal door onto the same idiom — no signature needed, since
  # `256` is past the tuple cap.
  def oversize_buffer_is_filled_before_it_is_read
    buf = Array.new(256)
    256.times { |i| buf[i] = i.to_s }
    buf.each(&:upcase)
    buf.first.upcase
  end

  # And the straight-line mutators that a `Nominal` carrier never widens:
  # `[]=`, `fill`, `map!`, `replace`, `concat` all rewrite the whole array.
  def whole_array_rewrites_are_readable(n)
    arr = Array.new(n)
    arr.fill("s")
    arr.each(&:upcase)
    other = Array.new(n)
    other.replace(["a", "b"])
    other.last.upcase
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

  # A UNION of literal containers widens MEMBERWISE. Judged wholesale, every arm
  # stayed a fixed-arity tuple, so appending to one and reading it back folded
  # `a[0].last == 5` always-falsey on correct code.
  def block_form_widens_a_union_of_containers(n, flag)
    a = Array.new(n) { flag ? [1] : [2] }
    assert_type("Array[Array[Integer]]", a)
    a[0] << 5
    puts "hit" if a[0].last == 5
  end

  # The fill form's spelling of the same shape, with a non-container arm that
  # must pass through untouched.
  def fill_form_widens_a_mixed_union(n, flag)
    a = Array.new(n, flag ? [] : "s")
    assert_type("Array[Array[Dynamic[top]] | String]", a)
    a
  end

  # Ruby's array-convertible COPY overload: `Array.new([1, 2])` is `[1, 2]`, not
  # two nils, which the gradual no-fill element absorbs.
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
