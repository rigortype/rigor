require "rigor/testing"
include Rigor::Testing

# `x.nil?` is `bool` whatever `x` is. With `x` an undeclared parameter it
# used to be `Dynamic[top]`, like every other call on an untyped receiver,
# because every dispatch tier needs a receiver it can name. The
# receiver-independent `BasicObject` / `Object` / `Kernel` selectors are
# answered from a fixed table instead.
class Probe
  def predicates(x)
    assert_type("bool", x.nil?)
    assert_type("bool", x.is_a?(String))
    assert_type("bool", x.respond_to?(:call))
    assert_type("bool", !x)
    assert_type("bool", x.frozen?)
    assert_type("bool", x.equal?(1))
  end

  def contracts(x)
    assert_type("String", x.inspect)
    assert_type("Integer", x.hash)
    assert_type("Integer", x.object_id)
  end

  # The exclusions. `x.class` must stay opaque: folding it to `Nominal[Class]`
  # erases the singleton, and `x.class.some_class_method` is ordinary Ruby.
  # `==` is the most commonly overridden method in the language, and `to_s`
  # waits on the `Array#[](Range)` optional-return noise it makes reachable.
  def excluded(x, y)
    assert_type("Dynamic[top]", x.class)
    assert_type("Dynamic[top]", x == y)
    assert_type("Dynamic[top]", x.to_s)
  end
end

# A named receiver still answers from its own signature — this tier sits
# below every real resolution tier and only replaces a `Dynamic[Top]`.
folded_nil = nil.nil?
folded_inspect = :sym.inspect
