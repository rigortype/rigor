require "rigor/testing"
include Rigor::Testing

# Issue #3115 — a recursion through a keyword argument answers what its positional twin answers. Each
# keyword row sits beside the positional form of the same method; the Ruby value is in the comment.
#
# Two rules carry the rows. A call whose keywords are all value-pinned unrolls by value, as an
# all-constant positional call does (the `n: 2` rows). A call with an unpinned keyword takes the widened
# retry, which widens the keyword's value as it widens a positional's (the `some_int` rows).
def some_int = [1, 2].sample

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

# Ruby: never returns (SystemStackError). No base case, so `bot` is the answer in both forms. These rows are last:
# the code after a `bot` call is unreachable.
assert_type("bot", subject.keyword_forever(n: 1))
assert_type("bot", subject.positional_forever(1))
