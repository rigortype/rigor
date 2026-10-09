require "rigor/testing"
include Rigor::Testing

# Issue #1691 — every core method Ruby 4.1 adds, called once. Each one
# reported `call.undefined-method` (or `call.wrong-arity`) before
# `data/core_overlay/` declared it.

assert_type("Integer", 5.bit_count)

bits = +"\xAA"
bits.bit_get(0)
bits.bit_get(0, lsb_first: false)
bits.bit_set?(1)
bits.bit_set(1)
bits.bit_set(4, 8, lsb_first: false)
bits.bit_clear(0..3)
bits.bit_flip(2)
assert_type("Integer", bits.bit_count)
bits.bit_count(0, 4)
bits.bit_count(..3, lsb_first: true)
bits.bitwise_not
bits.bitwise_not!
bits.bitwise_and("\x0F")
bits.bitwise_and!("\x0F")
bits.bitwise_or("\x0F")
bits.bitwise_or!("\x0F")
bits.bitwise_xor("\x0F")
bits.bitwise_xor!("\x0F")
assert_type("String", "hello".tr("e" => "er", "l" => ""))
(+"hello").tr!("e" => "a")

(1..10).clamp(2, 5)
(1..10).clamp(3..7)
(1..10).clamp(nil, 5)
(1..10).clamp(2.5, nil)

assert_type("Array[Module]", Comparable.descendants)
String.method_defined?(:upcase, true, true)

ENV.fetch_values("HOME", "PATH")
ENV.fetch_values("HOME") { |name| name.size }

module Ruby41Autoloads
  autoload_relative :Lazy, "lazy"
end
Ruby41Autoloads.autoload_relative(:Later, "later")
autoload_relative :TopLevel, "top_level"

class Ruby41Demo
  def clamp_range(range, lower)
    assert_type("Range[Integer]", range.clamp(2, 5))
    assert_type("Range[Integer]", range.clamp(lower, 5))
    assert_type("Range[Integer]", range.clamp(3..7))
  end

  def match(md)
    assert_type("Integer?", md.integer_at(1))
    md.integer_at("year", 16)
    md.integer_at(:year)
  end

  def locate(loc)
    range = loc.source_range
    assert_type("Ruby::SourceRange", range)
    range.path
    assert_type("String?", range.absolute_path)
    range.start_line
    range.start_column
    range.end_line
    range.end_column
    assert_type("Ruby::SourceRange?", proc { 1 }.source_range)
    assert_type("Ruby::SourceRange?", method(:locate).source_range)
    assert_type("Ruby::SourceRange?", Ruby41Demo.instance_method(:locate).source_range)
  end
end
