require "rigor/testing"
include Rigor::Testing

# Issue #2719 — `find` / `detect` / `rfind` whose block is one `is_a?` / `kind_of?` / `instance_of?` test on its one
# parameter answer an element that passed the test, or nil. Each comment gives what Ruby 4.0.5 answers for
# `ruby FILE 10 2.5`.

reals = ARGV.map { |a| a.to_c.real }
errs = ARGV.map { |a| a.include?(".") ? KeyError.new(a) : ArgumentError.new(a) }

# => 10
assert_type("Integer?", reals.find { |n| n.is_a?(Integer) })
# => 10
assert_type("Integer?", reals.detect { |n| n.kind_of?(Integer) })
# => 2.5
assert_type("Float?", reals.rfind { |n| n.is_a?(Float) })
# => #<ArgumentError: 10>; `instance_of?` is exact, and `KeyError` is not an `ArgumentError`
assert_type("ArgumentError?", errs.find { |e| e.instance_of?(ArgumentError) })
# => #<KeyError: 2.5>
assert_type("KeyError?", errs.find { |e| e.is_a?(IndexError) })

# Any other block shape keeps the element type: a second test, a second statement, an `ifnone` argument, a numbered
# parameter, and a test on something other than the parameter.
# => 10
assert_type("Numeric?", reals.find { |n| n.is_a?(Integer) || n.is_a?(Float) })
# => 10
assert_type("Numeric?", reals.find { |n| n.inspect; n.is_a?(Integer) })
# => 10; the block's value is its last statement, so the test decides nothing
assert_type("Numeric?", reals.find { |n| n.is_a?(Float); true })
# => 10
assert_type("Dynamic[top] | Numeric", reals.detect(-> { 0 }) { |n| n.is_a?(Integer) })
# => 10
assert_type("Numeric?", reals.find { _1.is_a?(Integer) })
# => 10
assert_type("Numeric?", reals.find { |n| errs.is_a?(Array) })

# A method outside the find family keeps its own answer: `pop` ignores the block.
# => 2.5
assert_type("Numeric?", reals.dup.pop { |n| n.is_a?(Integer) })
PREFIX = "1"
# => "10"
assert_type("String?", ARGV.find { |s| s.start_with?(PREFIX) })

# A class no element can be keeps the element type: a nil-only answer would read the test as never matching.
# => nil
assert_type("Numeric?", reals.find { |n| n.is_a?(String) })

# An `ifnone` answer is not an element, so it is not narrowed: Ruby answers it when no element passes. (A guard: the
# Proc's answer reads `Dynamic[top]` today, which carries no `nil` to narrow beside.)
# => 10
assert_type("Dynamic[top] | Numeric", reals.detect(-> { 0.5 if ARGV.empty? }) { |n| n.is_a?(Integer) })

# A test that is not a class test keeps the element type, even when another narrowing rule reads it.
TEN = 10
# => 10
assert_type("Numeric?", reals.find { |n| n == TEN })

# An untyped receiver's answer stays untyped: it carries no `nil` to keep.
def find_in_untyped(list)
  # => 10
  assert_type("Dynamic[top]", list.find { |n| n.is_a?(Integer) })
end
find_in_untyped(reals)

# A project class with no RBS cannot be ordered against the tested one, so the element type stands (a known limit).
class FindAnimal; end
class FindDog < FindAnimal; end
class FindCat < FindAnimal; end
pets = ARGV.map { |a| a.include?(".") ? FindCat.new : FindDog.new }
# => #<FindDog ...>
assert_type("FindCat | FindDog | nil", pets.find { |n| n.is_a?(FindDog) })
