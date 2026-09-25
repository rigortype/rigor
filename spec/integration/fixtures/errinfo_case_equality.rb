# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
include Rigor::Testing

# Issue #1360 — `rescue` matches with the class's singleton `===`, which a `define_singleton_method(:===)` may make
# accept an exception that is not an instance of it (Ruby: the RuntimeError). The discovery tables do not place such a
# definition on its class, so in a file that holds one no rescued class binds `$!` as itself.
class Matchy < StandardError
  define_singleton_method(:===) { |_exception| true }
end

def defined_case_equality
  raise "boom"
rescue Matchy
  assert_type("Dynamic[top]", $!)
end

# The file-wide decline reaches a class that defines no `===` too (Ruby: the ArgumentError).
def other_class
  Integer("x")
rescue ArgumentError
  assert_type("Dynamic[top]", $!)
end
# rubocop:enable Style/SpecialGlobalVars
