require "rigor/testing"
include Rigor::Testing

# Issue #3162 — a recursion's return summary is the return of the outer call's body, typed for the outer
# call's arguments. An in-cycle call reads it only when those arguments cover its own; a call that
# passes something else (`k + 1` against `k = 1`) answers `Dynamic[top]`, so a base case that returns
# the parameter (`k`) or branches on it (`v.nil?`) no longer answers for every depth with the first
# frame's value. Each row has its keyword twin; the Ruby values are in the comments (`ruby -e`, Ruby
# 4.0.5), and every one of them is a member of the asserted type or covered by its `Dynamic[top]`.
def some_int = [1, 2].sample
def coin = [true, false].sample
def some_array = [[], [1], [1, 2], [1, 2, 3]].sample

class ArgumentRecursion
  def acc(n, k) = n <= 0 ? k : acc(n - 1, k + 1)
  def acc_kw(n:, k:) = n <= 0 ? k : acc_kw(n: n - 1, k: k + 1)

  def ps(k, *a) = a.size > 2 ? k : ps(k + 1, *a, 1)
  def ks(*a, k:) = a.size > 2 ? k : ks(*a, 1, k: k + 1)

  def restp(*args) = args.size > 3 ? args.last : restp(*args, 1)
  def restk(**kw) = kw.size > 3 ? kw.values.last : restk(**kw, "k#{kw.size}": 1)

  def un(v) = v.is_a?(Integer) ? (v > 0 ? un(v - 1) : :int) : :other
  def un_kw(v:) = v.is_a?(Integer) ? (v > 0 ? un_kw(v: v - 1) : :int) : :other

  def opt(v) = v.nil? ? :none : (v > 0 ? opt(v - 1) : :zero)
  def opt_kw(v:) = v.nil? ? :none : (v > 0 ? opt_kw(v: v - 1) : :zero)

  def cnt(n, step = 1) = n <= 0 ? step : cnt(n - step, step)
  def cnt_kw(n:, step: 1) = n <= 0 ? step : cnt_kw(n: n - step, step: step)

  def tog(n, f = false) = n <= 0 ? f : tog(n - 1, !f)
  def tog_kw(n:, f: false) = n <= 0 ? f : tog_kw(n: n - 1, f: !f)

  def mode(n, m = :fast) = n <= 0 ? m : mode(n - 1, :slow)
  def mode_kw(n:, m: :fast) = n <= 0 ? m : mode_kw(n: n - 1, m: :slow)

  def str(n, s = "") = n <= 0 ? s : str(n - 1, s + "x")
  def str_kw(n:, s: "") = n <= 0 ? s : str_kw(n: n - 1, s: s + "x")

  def asg(n, k)
    return k if n <= 0

    k += 1
    asg(n - 1, k)
  end

  def asg_kw(n:, k:)
    return k if n <= 0

    k += 1
    asg_kw(n: n - 1, k: k)
  end

  def blk(n, k) = n <= 0 ? k : [1].map { |x| blk(n - x, k + x) }.first
  def blk_kw(n:, k:) = n <= 0 ? k : [1].map { |x| blk_kw(n: n - x, k: k + x) }.first

  def same(n) = n == 1 ? same(:sym) : (coin ? n : same(n))
  def same_kw(n:) = n == 1 ? same_kw(n: :sym) : (coin ? n : same_kw(n: n))

  def nest(n, t = []) = n <= 0 ? t : nest(n - 1, [t])
  def nest_kw(n:, t: []) = n <= 0 ? t : nest_kw(n: n - 1, t: [t])

  def lit(n, k) = n <= 0 ? k : lit(n - 1, 0)
  def lit_kw(n:, k:) = n <= 0 ? k : lit_kw(n: n - 1, k: 0)

  def spin(n) = spin(n + 1)
  def spin_kw(n:) = spin_kw(n: n + 1)

  # Ruby: neither call returns (SystemStackError). `n + 1` is not covered by `1 | 2`, but the widened
  # retry finds no exit either, so the answer stays `bot`. The rows sit in a method body: the code after
  # a `bot` call is unreachable.
  def diverging_rows
    assert_type("bot", spin(some_int))
    assert_type("bot", spin_kw(n: some_int))
  end

  def nested(k, t) = t == :a ? [nested(some_int, :b)] : (coin ? :base : nested(3, :a))
  def nested_kw(k:, t:) = t == :a ? [nested_kw(k: some_int, t: :b)] : (coin ? :base : nested_kw(k: 3, t: :a))

  def first_of(n) = n == 1 ? first_of(:sym).first : (coin ? [n] : [first_of(n)])
  def first_of_kw(n:) = n == 1 ? first_of_kw(n: :sym).first : (coin ? [n] : [first_of_kw(n: n)])

  def blk_literal(x, &b) = coin ? yield : blk_literal(x) { :other }
  def blk_literal_kw(x:, &b) = coin ? yield : blk_literal_kw(x: x) { :other }
  def blk_unnamed(x) = coin ? yield : blk_unnamed(x) { :other }
  def blk_unnamed_kw(x:) = coin ? yield : blk_unnamed_kw(x: x) { :other }
  def blk_passed(x, &b) = coin ? yield : blk_passed(x, &b)
  def blk_passed_kw(x:, &b) = coin ? yield : blk_passed_kw(x: x, &b)
  def blk_foreign(x, o, &b) = coin ? yield : blk_foreign(x, o, &o)
  def blk_foreign_kw(x:, o:, &b) = coin ? yield : blk_foreign_kw(x: x, o: o, &o)

  def fib(n) = n < 2 ? n : fib(n - 1) + fib(n - 2)
  def fib_kw(n:) = n < 2 ? n : fib_kw(n: n - 1) + fib_kw(n: n - 2)

  def ping(n, k) = n <= 0 ? k : pong(n - 1, k + 1)
  def pong(n, k) = ping(n, k)
  def ping_kw(n:, k:) = n <= 0 ? k : pong_kw(n: n - 1, k: k + 1)
  def pong_kw(n:, k:) = ping_kw(n: n, k: k)
end

subject = ArgumentRecursion.new

# Ruby: 1..10. The base case returns `k`, which every call passes on as `k + 1`.
assert_type("1 | Dynamic[top]", subject.acc(rand(10), 1))
assert_type("1 | Dynamic[top]", subject.acc_kw(n: rand(10), k: 1))

# Ruby: 4. An all-constant call still unrolls by value.
assert_type("4", subject.acc(3, 1))
assert_type("4", subject.acc_kw(n: 3, k: 1))

# Ruby: 3 or 4, and 1..5. The rest grows by one element a call and `k` by one. The positional form
# starts from a pinned rest, takes the widened retry (#3115) and answers that retry's floor.
assert_type("Dynamic[top]", subject.ps(some_int, 1))
assert_type("1 | 2 | Dynamic[top]", subject.ks(*some_array, k: some_int))

# Ruby: 1. The rest (or the keyword rest) grows until the base case reads its last element.
assert_type("Dynamic[top]", subject.restp(1, some_int))
assert_type("Dynamic[top]", subject.restk(a: 1, b: some_int))

# Ruby: :int or :other. The outer `1 | 2` prunes `v > 0`'s else branch; the recursion reaches it with 0,
# which `1 | 2 | :sym` does not cover.
assert_type(":other | Dynamic[top]", subject.un(coin ? some_int : :sym))
assert_type(":other | Dynamic[top]", subject.un_kw(v: coin ? some_int : :sym))

# Ruby: :none or :zero.
assert_type(":none | Dynamic[top]", subject.opt(coin ? nil : some_int))
assert_type(":none | Dynamic[top]", subject.opt_kw(v: coin ? nil : some_int))

# Ruby: 1. `step` is passed through unchanged, so it keeps the first frame's value.
assert_type("1", subject.cnt(some_int))
assert_type("1", subject.cnt_kw(n: some_int))

# Ruby: true or false. The default starts the slot and `!f` passes `true`.
assert_type("Dynamic[top] | false", subject.tog(rand(10)))
assert_type("Dynamic[top] | false", subject.tog_kw(n: rand(10)))

# Ruby: :fast or :slow.
assert_type(":fast | Dynamic[top]", subject.mode(rand(10)))
assert_type(":fast | Dynamic[top]", subject.mode_kw(n: rand(10)))

# Ruby: "", "x", "xx", ...
assert_type("\"\" | Dynamic[top]", subject.str(rand(10)))
assert_type("\"\" | Dynamic[top]", subject.str_kw(n: rand(10)))

# Ruby: 1..10. The call passes `k` by name after the body assigned it, and from inside a block: the
# cover test reads the bindings the call was built with, not the call's syntax.
assert_type("1 | Dynamic[top]", subject.asg(rand(10), 1))
assert_type("1 | Dynamic[top]", subject.asg_kw(n: rand(10), k: 1))
assert_type("1 | Dynamic[top]", subject.blk(rand(10), 1))
assert_type("1 | Dynamic[top]", subject.blk_kw(n: rand(10), k: 1))

# Ruby: :sym. The `same(:sym)` unroll frame calls itself with the constant it holds, but the summary it
# would read is the outer `same(1)`'s, which `n = 1` does not cover: a value-keyed re-entry is tested too.
assert_type("Dynamic[top]", subject.same(1))
assert_type("Dynamic[top]", subject.same_kw(n: 1))

# Ruby: an Array holding :base or a deeper Array. The `(some_int, :b)` frame under the constant call owns
# a summary of its own, and the outer summary is back in place for the `(3, :a)` re-entry inside it.
assert_type("[:base | Dynamic[top]]", subject.nested(3, :a))
assert_type("[:base | Dynamic[top]]", subject.nested_kw(k: 3, t: :a))

# Ruby: :sym or an Array. The `first_of(:sym)` unroll frame's own re-entry does not read `first_of(1)`'s
# summary.
assert_type("Dynamic[top]", subject.first_of(1))
assert_type("Dynamic[top]", subject.first_of_kw(n: 1))

# Ruby: 1 or :other. The re-entry runs with a block of its own, so `yield` there is not the frame's.
assert_type("1 | Dynamic[top]", subject.blk_literal(1) { 1 })
assert_type("1 | Dynamic[top]", subject.blk_literal_kw(x: 1) { 1 })
assert_type("1 | Dynamic[top]", subject.blk_unnamed(1) { 1 })
assert_type("1 | Dynamic[top]", subject.blk_unnamed_kw(x: 1) { 1 })

# Ruby: 1. The def's own block parameter passed on is the frame's block.
assert_type("1", subject.blk_passed(1) { 1 })
assert_type("1", subject.blk_passed_kw(x: 1) { 1 })

# Ruby: 1 or :o. `&o` is another block.
assert_type("1 | Dynamic[top]", subject.blk_foreign(1, -> { :o }) { 1 })
assert_type("1 | Dynamic[top]", subject.blk_foreign_kw(x: 1, o: -> { :o }) { 1 })

# Ruby: [], [[]], [[[]]], ... A parameter one level deeper each call.
assert_type("Dynamic[top] | []", subject.nest(rand(10)))
assert_type("Dynamic[top] | []", subject.nest_kw(n: rand(10)))

# Ruby: 0..9. `Integer` covers the `0` the recursion passes, so the summary is read and nothing floors.
assert_type("Integer", subject.lit(rand(10), rand(10)))
assert_type("Integer", subject.lit_kw(n: rand(10), k: rand(10)))

# Ruby: 102334155. The unroll runs out of fuel; the answer is not a constant.
assert_type("Dynamic[top]", subject.fib(40))
assert_type("Dynamic[top]", subject.fib_kw(n: 40))

# Ruby: 1..10. Mutual recursion keeps the `Dynamic[top]` floor it had.
assert_type("1 | Dynamic[top]", subject.ping(rand(10), 1))
assert_type("1 | Dynamic[top]", subject.ping_kw(n: rand(10), k: 1))

# Ruby: both branches run. With the first frame's `k = 1` as the answer, `== 5` folded to false.
deep = subject.acc(rand(10), 1)
puts "deep" if deep == 5 # reachable: acc
puts "int" if subject.un(coin ? some_int : :sym) == :int # reachable: un
puts "deeper" if subject.nested(3, :a).first != :base # reachable: nested
puts "sym" if subject.first_of(1).is_a?(Symbol) # reachable: first_of
puts "other" if (subject.blk_literal(1) { 1 }) == :other # reachable: blk_literal
puts "other" if (subject.blk_unnamed(1) { 1 }) == :other # reachable: blk_unnamed
