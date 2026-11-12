require "rigor/testing"
include Rigor::Testing

# Issue #3115 — a recursion through a keyword argument answers what its positional twin answers. Each
# keyword row sits beside the positional form of the same method; the Ruby value is in the comment.
#
# Two rules carry the rows. A call whose keywords are all value-pinned unrolls by value, as an
# all-constant positional call does (the `n: 2` rows). A call with an unpinned keyword takes the widened
# retry, which widens the keyword's value as it widens a positional's (the `some_int` rows).
def some_int = [1, 2].sample
def coin = [true, false].sample

class KeywordRecursion
  def keyword(a, n:) = n > 0 ? keyword(a, n: n - 1) : a
  def positional(a, n) = n > 0 ? positional(a, n - 1) : a

  def keyword_after_rest(*a, k:) = k.zero? ? :done : keyword_after_rest(*a, k: k - 1)
  def positional_before_rest(k, *a) = k.zero? ? :done : positional_before_rest(k - 1, *a)

  def keyword_default(a, n: 3) = n > 0 ? keyword_default(a, n: n - 1) : a
  def positional_default(a, n = 3) = n > 0 ? positional_default(a, n - 1) : a

  def keyword_rest(a, **kw) = kw[:n].to_i > 0 ? keyword_rest(a, n: kw[:n] - 1) : a
  def positional_hash(a, kw) = kw[:n].to_i > 0 ? positional_hash(a, { n: kw[:n] - 1 }) : a

  def keyword_ping(n:) = n > 0 ? keyword_pong(n: n - 1) : :base
  def keyword_pong(n:) = keyword_ping(n: n)
  def positional_ping(n) = n > 0 ? positional_pong(n - 1) : :base
  def positional_pong(n) = positional_ping(n)

  def keyword_forever(n:) = keyword_forever(n: n)
  def positional_forever(n) = positional_forever(n)

  def keyword_block(n:, &blk) = n > 0 ? keyword_block(n: n - 1, &blk) : yield
  def positional_block(n, &blk) = n > 0 ? positional_block(n - 1, &blk) : yield

  def keyword_toggle(n:, f: false) = n > 0 ? keyword_toggle(n: n - 1, f: !f) : f
  def positional_toggle(n, f = false) = n > 0 ? positional_toggle(n - 1, !f) : f

  def keyword_build(depth:, acc: []) = depth.zero? ? acc : keyword_build(depth: depth - 1, acc: acc + [depth])
  def positional_build(depth, acc = []) = depth.zero? ? acc : positional_build(depth - 1, acc + [depth])

  def keyword_rest_returned(a, **kw) = a > 0 ? keyword_rest_returned(a - 1, **kw) : kw
  def positional_hash_returned(a, kw) = a > 0 ? positional_hash_returned(a - 1, kw) : kw
  def keyword_hash_returned(a, opts: {}) = a > 0 ? keyword_hash_returned(a - 1, opts: opts) : opts
  def positional_tuple_returned(a, t) = a > 0 ? positional_tuple_returned(a - 1, t) : t

  def keyword_nested(opts:) = opts[:n] > 0 ? keyword_nested(opts: { n: opts[:n] - 1 }) : :base
  def keyword_tuple(xs:) = xs[0] > 0 ? keyword_tuple(xs: [xs[0] - 1]) : :base
  def positional_tuple(xs) = xs[0] > 0 ? positional_tuple([xs[0] - 1]) : :base

  def positional_config(n, mode = :fast) = n > 0 ? positional_config(n - 1, mode) : mode
  def keyword_config(n:, mode: :fast) = n > 0 ? keyword_config(n: n - 1, mode:) : mode
  def positional_step(n, step = 1) = n <= 0 ? step : positional_step(n - step, step)
  def keyword_step(n:, step: 1) = n <= 0 ? step : keyword_step(n: n - step, step: step)

  def positional_omitted(n, mode = :fast) = n > 0 ? positional_omitted(n - 1) : mode
  def positional_splatted(n, mode = :fast) = n > 0 ? positional_splatted(*[n - 1, :slow]) : mode

  def positional_assigned(n, mode = :fast)
    mode = :slow if n == 1
    n > 0 ? positional_assigned(n - 1, mode) : mode
  end

  def rest_kept(n, *a) = n > 0 ? rest_kept(n - 1, *a) : a
  def rest_grown(n, *a) = n > 0 ? rest_grown(n - 1, *a, 1) : a
  def keyword_rest_kept(n, **kw) = n > 0 ? keyword_rest_kept(n - 1, **kw) : kw
  def keyword_rest_grown(n, **kw) = n > 0 ? keyword_rest_grown(n - 1, **kw, z: 1) : kw

  # Ruby: neither call returns (SystemStackError). No base case, so `bot` is the answer in both forms. The
  # rows sit in a method body: the code after a `bot` call is unreachable.
  def diverging_rows
    assert_type("bot", keyword_forever(n: 1))
    assert_type("bot", positional_forever(1))
  end
end

subject = KeywordRecursion.new

# Ruby: 1. An unpinned keyword: the widened retry reaches the base case.
assert_type("Integer", subject.keyword(1, n: some_int))
assert_type("Integer", subject.positional(1, some_int))

# Ruby: 1. A pinned keyword: the call unrolls by value.
assert_type("1", subject.keyword(1, n: 2))
assert_type("1", subject.positional(1, 2))

# Ruby: :done. A call-site splat beside the keyword.
assert_type(":done", subject.keyword_after_rest(*[1], k: 3))
assert_type(":done", subject.positional_before_rest(3, *[1]))
assert_type(":done", subject.keyword_after_rest(1, k: 3))
assert_type(":done", subject.positional_before_rest(3, 1))
assert_type(":done", subject.keyword_after_rest(1, k: some_int))
assert_type(":done", subject.positional_before_rest(some_int, 1))

# Ruby: 1. The keyword's default starts the recursion.
assert_type("1", subject.keyword_default(1))
assert_type("1", subject.positional_default(1))

# Ruby: 1. `**kw` collects the keyword.
assert_type("1", subject.keyword_rest(1, n: 2))
assert_type("1", subject.positional_hash(1, { n: 2 }))
assert_type("Integer", subject.keyword_rest(1, n: some_int))
assert_type("Integer", subject.positional_hash(1, { n: some_int }))

# Ruby: :base. Mutual recursion through keywords.
assert_type(":base", subject.keyword_ping(n: 2))
assert_type(":base", subject.positional_ping(2))

# Ruby: :blk. A block-taking recursion.
assert_type(":blk", subject.keyword_block(n: 2) { :blk })
assert_type(":blk", subject.positional_block(2) { :blk })
assert_type(":blk", subject.keyword_block(n: some_int) { :blk })
assert_type(":blk", subject.positional_block(some_int) { :blk })

# A parameter the recursion rebinds, with an unpinned counter. The widened retry types the body for every
# call the recursion makes, and a recursive call passes the slot something else (`f: !f`, `acc + [depth]`),
# so neither the default's literal nor the outer call's own argument is the answer.
# Ruby: true for 1, false for 2.
assert_type("Dynamic[top]", subject.keyword_toggle(n: some_int))
assert_type("Dynamic[top]", subject.positional_toggle(some_int))
assert_type("Dynamic[top]", subject.keyword_toggle(n: some_int, f: false))
assert_type("Dynamic[top]", subject.positional_toggle(some_int, false))
# Ruby: false. A pinned counter unrolls, default included.
assert_type("false", subject.keyword_toggle(n: 2))
assert_type("false", subject.positional_toggle(2))
# Ruby: [1] for 1, [2, 1] for 2.
assert_type("Dynamic[top]", subject.keyword_build(depth: some_int))
assert_type("Dynamic[top]", subject.positional_build(some_int))
assert_type("Dynamic[top]", subject.keyword_build(depth: some_int, acc: []))
assert_type("Dynamic[top]", subject.positional_build(some_int, []))
# Ruby: [2, 1].
assert_type("[2, 1]", subject.keyword_build(depth: 2))
assert_type("[2, 1]", subject.positional_build(2))
# Ruby: 1 or 2, the argument.
assert_type("Integer", subject.keyword_default(some_int))
assert_type("Integer", subject.positional_default(some_int))

# A pinned shape the recursion hands back: the unroll keeps it, as it keeps a tuple.
# Ruby: { x: 1 }, { x: 1 }, { x: 1 }, {}, [1, 2].
assert_type("{ x: 1 }", subject.keyword_rest_returned(2, x: 1))
assert_type("{ x: 1 }", subject.positional_hash_returned(2, { x: 1 }))
assert_type("{ x: 1 }", subject.keyword_hash_returned(2, opts: { x: 1 }))
assert_type("{}", subject.keyword_hash_returned(2))
assert_type("[1, 2]", subject.positional_tuple_returned(2, [1, 2]))

# A pin below the first level: a shape in a keyword, a tuple in a keyword, a tuple, a union of shapes.
# Ruby: :base for the first three, 1 for the last.
assert_type(":base", subject.keyword_nested(opts: { n: some_int }))
assert_type(":base", subject.keyword_tuple(xs: [some_int]))
assert_type(":base", subject.positional_tuple([some_int]))
assert_type("Integer", subject.positional_hash(1, coin ? { n: 2 } : { n: 2, m: 1 }))

# A parameter every recursive call passes through unchanged keeps its binding in the retry.
# Ruby: :fast, :fast (the `mode:` shorthand), 1, 1.
assert_type(":fast", subject.positional_config(some_int))
assert_type(":fast", subject.keyword_config(n: some_int))
assert_type("1", subject.positional_step(some_int))
assert_type("1", subject.keyword_step(n: some_int))
# Ruby: [:a], { a: 1 }. `*a` passed as `*a` and `**kw` as `**kw` are unchanged; the values widen.
assert_type("[Symbol]", subject.rest_kept(some_int, :a))
assert_type("{ a: Integer }", subject.keyword_rest_kept(some_int, a: 1))

# The other ways a recursive call rebinds a parameter.
# Ruby: :fast. The recursive call omits `mode`, so the default replaces the outer call's 5.
assert_type("Dynamic[top]", subject.positional_omitted(some_int, 5))
# Ruby: :slow. A splat at the recursive call may reach every positional from its own slot on.
assert_type("Dynamic[top]", subject.positional_splatted(some_int))
# Ruby: :slow. The body assigns the parameter before it passes it on.
assert_type(":slow | Dynamic[top]", subject.positional_assigned(some_int))
# Ruby: [:a, 1, 1], { a: 1, z: 1 }. The rest parameter grows at each call.
assert_type("Dynamic[top]", subject.rest_grown(some_int, :a))
assert_type("Dynamic[top]", subject.keyword_rest_grown(some_int, a: 1))
