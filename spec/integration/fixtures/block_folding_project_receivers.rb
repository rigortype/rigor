require "rigor/testing"
include Rigor::Testing

# Issue #3242 — BlockFolding folded `find` / `detect` / `find_index` with a
# constant-falsey block to `nil`, `count` to `0`, and `all?` / `any?` /
# `none?` to a boolean on any receiver, so a project class that defines the
# method itself was typed with core's answer instead of its own.

# A project class defining every folded method itself.
class Bag
  def find
    yield
    8
  end

  def detect
    yield
    9
  end

  def find_index
    yield
    10
  end

  def count
    yield
    11
  end

  def all?
    yield
    12
  end

  def any?
    yield
    13
  end

  def none?
    yield
    14
  end
end

bag = Bag.new
assert_type("8", bag.find { false })
assert_type("9", bag.detect { false })
assert_type("10", bag.find_index { false })
assert_type("11", bag.count { false })
assert_type("12", bag.all? { false })
assert_type("13", bag.any? { false })
assert_type("14", bag.none? { false })

# A subclass of a core collection is its own nominal, so its overrides win too.
class TaggedList < Array
  def find
    yield
    20
  end

  def count
    yield
    21
  end

  def any?
    yield
    22
  end
end

list = TaggedList.new
assert_type("20", list.find { false })
assert_type("21", list.count { false })
assert_type("22", list.any? { false })

# A class including Enumerable that overrides `detect` keeps its own answer.
class Shelf
  include Enumerable

  def each
    yield 1
  end

  def detect
    yield
    30
  end
end

assert_type("30", Shelf.new.detect { false })

# Controls: core receivers keep the folds.
assert_type("nil", [1, 2].find { false })
assert_type("nil", { a: 1 }.detect { false })
assert_type("nil", (1..3).find_index { false })
assert_type("0", [1, 2].count { false })
assert_type("false", [1, 2].any? { false })
assert_type("true", [1, 2].none? { false })

def core_nominal(items)
  assert_type("nil", items.find { false })
  assert_type("0", items.count { false })
end
core_nominal(Integer(ARGV.first) > 0 ? [1] : [2, 3])
