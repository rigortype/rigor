require "rigor/testing"
include Rigor::Testing

# Issues #2128 and #2127 — a `return` in a loop body, or in a block a project method runs more than once, that only a
# later iteration or run reaches (its condition reads a counter the body moves) joins the method's return type. Each
# comment gives what Ruby 4.0.5 answers. A caller's test on such a method is not reported as constant.

# `within?([1, 2, 3, 4, 5])` returns false, `within?([1])` true (#2128).
def within?(items)
  seen = 0
  while seen < items.size
    seen += 1
    return false if seen > 3
  end
  true
end
assert_type("bool", within?([1]))

# `use([1, 2, 3, 4, 5])` returns :big.
def use(items)
  return :big unless within?(items)

  :small
end

# `for_return` returns :f.
def for_return
  n = 0
  for x in [1, 2, 3]
    return :f if (n += 1) > 2
  end
  :fall
end
assert_type(":f | :fall", for_return)

# `for_break` returns :b: the `break` a later iteration takes gives the loop its value.
def for_break
  n = 0
  for x in [1, 2, 3]
    break :b if (n += 1) > 2
  end
end
assert_type(":b | [1, 2, 3]", for_break)

# `yielder_return` returns :ret (#2127).
def yielder
  yield
  yield
end

def yielder_return
  seen = 0
  yielder { return :ret if (seen += 1) > 1 }
  :fall
end
assert_type(":fall | :ret", yielder_return)

# The idiomatic wrapper: `Bag.new([1, 2, 3, 4, 5]).use` returns :big.
class Bag
  def initialize(items) = @items = items

  def each
    @items.each { |i| yield i }
  end

  def each_forwarded(&blk) = @items.each(&blk)

  def within?
    seen = 0
    each { return false if (seen += 1) > 3 }
    true
  end

  def within_forwarded?
    seen = 0
    each_forwarded { return false if (seen += 1) > 3 }
    true
  end

  def use
    return :big unless within?

    :small
  end
end
assert_type("bool", Bag.new([1]).within?)
assert_type("bool", Bag.new([1]).within_forwarded?)

# Controls. A project method that runs its block once keeps the first run: `once_return` returns :fall.
def once
  yield
end

def once_return
  seen = 0
  once { return :ret if (seen += 1) > 1 }
  :fall
end
assert_type(":fall", once_return)

# A `return` no iteration reaches stays out: `never_return` returns :fall.
def never_return
  seen = 0
  while seen < 3
    seen += 1
    return :never if seen.nil?
  end
  :fall
end
assert_type(":fall", never_return)
