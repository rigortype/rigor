require "rigor/testing"
include Rigor::Testing

# Issues #1216 and #2031 — a loop's value. A `for` loop is `coll.each { … }`, so it answers what that `each`
# answers (the collection, for an Array, a Hash or a Range) unless a `break` ends it with its value. A `while`
# / `until` loop answers `nil` when its predicate ends it and a `break`'s value when the `break` does. Each comment
# gives what Ruby 4.0.5 answers. GENUINE-UNDEFINED marks a call Ruby raises on.

# `for_value` returns 2: the loop answers `[1, 2]`.
def for_value
  r = for i in [1, 2]; end
  assert_type("[1, 2]", r)
  r.size
end

# `for_empty` returns 0: the body never runs, and the loop still answers the collection.
def for_empty
  r = for i in []; end
  r.size
end

# `for_hash` returns {a: 1}, `for_range` 1..3.
def for_hash
  h = { a: 1 }
  r = for k, v in h; end
  assert_type("{ a: 1 }", r)
end

def for_range
  r = for i in 1..3; end
  assert_type("1..3", r)
end

# `for_words("a b")` returns ["a", "b"], as does `for_non_empty("a b")`; `for_union(true)` returns [1].
def for_words(s)
  r = for w in "#{s}".split; end
  assert_type("Array[String]", r)
end

def for_non_empty(s)
  xs = "#{s}".split
  return if xs.empty?

  r = for w in xs; end
  assert_type("non-empty-array[String]", r)
end

def for_union(c)
  xs = c ? [1] : [2, 3]
  r = for i in xs; end
  assert_type("[1] | [2, 3]", r)
end

# `for_break` returns :b.
def for_break
  r = for i in [1, 2]; break :b if i == 2; end
  assert_type(":b | Array[Integer]", r)
end

# `each` answers the collection after the body ran, so a body that may change its contents leaves neither its
# shape nor its size: `for_pop` returns :one (the loop answers [1]), `for_clear` [], `for_append` [1, 2, "s"],
# `for_alias_pop` [1], `for_delete` {}, `for_ivar_pop` [1]. A Set's `each` is not read as answering itself:
# `for_set` returns the Set.
def for_pop
  a = [1, 2]
  r = for i in a
    a.pop
  end
  assert_type("Array[1 | 2 | Dynamic[top]] | Array[Integer]", r)
  r.size == 1 ? :one : :two
end

def for_clear
  a = [1, 2]
  r = for i in a
    a.clear
  end
  assert_type("Array[1 | 2 | Dynamic[top]] | Array[Integer]", r)
end

def for_append
  a = [1, 2]
  r = for i in a
    a << "s" if i == 1
  end
  assert_type("Array[1 | 2 | Dynamic[top]] | Array[Integer]", r)
end

def for_alias_pop
  a = [1, 2]
  b = a
  r = for i in a
    b.pop
  end
  assert_type("Array[Integer]", r)
  r.size == 1 ? :one : :two
end

def for_delete
  h = { a: 1 }
  r = for k, v in h
    h.delete(:a)
  end
  assert_type("Hash[Dynamic[top] | Symbol, 1 | Dynamic[top]] | Hash[Symbol, Integer]", r)
end

def for_ivar_pop
  @items = [1, 2]
  r = for i in @items
    @items.pop
  end
  r.size == 1 ? :one : :two
end

def for_set
  s = Set.new([1, 2])
  r = for i in s; end
  assert_type("Dynamic[top]", r)
end

# A collection whose `each` is not known to answer itself leaves the value gradual: `for_project` answers nil, what
# `Bag#each` answers, and `for_dynamic(xs)` whatever `xs.each` does.
class Bag
  def each = yield(1)
end

def for_project
  r = for i in Bag.new; end
  assert_type("Dynamic[top]", r)
end

def for_dynamic(xs)
  r = for i in xs; end
  assert_type("Dynamic[top]", r)
  r.size
end

# `while_break` returns "four" (issue #2031's report).
def while_break
  i = 0
  k = 10
  x = while i < k
    i += 1
    if i == 4
      @r = "four"
      break @r
    end
  end
  assert_type("\"four\"?", x)
end

# `until_break(0)` returns :b, `until_break(5)` nil.
def until_break(n)
  x = until n > 3
    n += 1
    break :b if n == 2
  end
  assert_type(":b?", x)
end

# `modifier_break(0)` returns :m, `modifier_break(-1)` nil.
def modifier_break(n)
  x = ((break :m if n.zero?) while n > -1)
  assert_type(":m?", x)
end

# `counter_break` returns 6: the `break` reads the loop-carried counter.
def counter_break
  i = 0
  x = while i < 10
    i += 1
    break i if i > 5
  end
  assert_type("Integer[6..10]?", x)
end

# `no_break(2)` returns nil.
def no_break(n)
  x = while n > 0
    n -= 1
  end
  assert_type("nil", x)
end

# A `break` in a nested block or loop ends that construct, not this loop: `nested_break(true)` returns nil.
def nested_break(c)
  x = while c
    [1].each { break 2 }
    while true
      break 3
    end
    c = false
  end
  assert_type("nil", x)
end

# A literal `while true` / `until false` is ended only by its `break`: `endless` returns 2, `endless_until` :u.
def endless
  x = while true
    break 1
  end
  x + 1
end

def endless_until
  x = until false
    break :u
  end
  assert_type(":u", x)
end

# A `begin … end while` body runs once before its predicate is tested, so a `break` only that first run takes
# counts: `begin_first_run` returns :b.
def begin_first_run
  state = :idle
  x = (begin
    break :b if state == :idle
    state = :run
  end while state != :idle)
  assert_type(":b?", x)
end

# A loop in value position answers as its statement form does: `value_position` returns [[1], [[1]], nil].
def value_position
  [[while true; break 1; end], [for i in [1]; end], [while false; end].first]
end
assert_type("[[1], [[1]], nil]", value_position)

# A true positive kept: `genuine(2)` raises, since a loop with no `break` answers nil.
def genuine(n)
  x = while n > 0
    n -= 1
  end
  x.size # GENUINE-UNDEFINED
end
