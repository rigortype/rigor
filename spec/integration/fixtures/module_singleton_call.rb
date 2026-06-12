require "rigor/testing"
include Rigor::Testing

# Module-singleton call resolution (ADR-57 follow-up): a call on a
# module/class CONSTANT to a user-side `def self.x` / `module_function`
# method re-types the body with the call's argument types bound, exactly
# as the instance-side ancestor walk does for `Nominal` receivers.

module Util
  def self.triple(x) = x * 3
end

class Calc
  def self.double(x) = x * 2
  def self.via_helper(x) = helper(x)
  def self.helper(y) = y + 100
end

module Funcs
  module_function

  def quad(x) = x * 4
end

# `def self.x` on a module / class constant folds with constant args.
assert_type("15", Util.triple(5))
assert_type("10", Calc.double(5))

# A singleton method calling another singleton helper via implicit self.
assert_type("102", Calc.via_helper(2))

# `module_function` method called on the module constant.
assert_type("12", Funcs.quad(3))

# Foreign / RBS-known singleton stays catalog-typed, untouched.
assert_type("2.0", Math.sqrt(4.0))
