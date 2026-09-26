require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1429 — a class guard disjoint from the receiver's inferred `Nominal` narrows the receiver to `bot` in the arm,
# so the guarded class never reaches a typed boundary after it. Keeping the arm without leaking its type is #1465; each
# shape below is one its design must keep quiet. The signatures in `sig/arm_values.rbs` are the correct ones, and Ruby
# 4.0.5 runs every method below without error.

class Sink
  def self.take_io(io) = 1
  def self.take_str(str) = 1

  # Ruby 4.0.5: 1 (`STDOUT` is not a `StringIO`).
  def pass_io
    io = STDOUT
    io.truncate(0) if io.is_a?(StringIO)
    Sink.take_io(io) # QUIET-1429
  end

  # Ruby 4.0.5: 1.
  def pass_str(value)
    value.to_s if value.is_a?(Symbol)
    Sink.take_str(value) # QUIET-1429
  end

  # Ruby 4.0.5: the String it was given.
  def ret_str(value)
    puts value.inspect if value.is_a?(Symbol)
    value
  end

  # Ruby 4.0.5: the stripped String.
  def norm2(value) = value.is_a?(Symbol) ? value : value.strip

  # Issue #655's shadowed pattern, passed into a `(String)` parameter (Ruby 4.0.5: 1, from the `else` arm).
  def shadow_into_string(other) = Sink.take_str(case other when Random then 1 else "else" end) # QUIET-1429

  # As before #1429, an `if` keeps its arm's value (a `case` value drops the arm, see `locals.rb`), and the variable the
  # guard narrowed joins back as it was.
  def arm_value_types(value)
    assert_type('"no" | :yes', value.is_a?(Symbol) ? :yes : "no")
    value.to_s if value.is_a?(Symbol)
    assert_type("String", value)
  end

  # Ruby 4.0.5: nil.
  def arm_binding(value)
    label = value.is_a?(Symbol) ? :sym : nil
    assert_type(":sym?", label)
  end

  class Random
  end
end

# Issue #1429 — a value-position `case` types each arm under the subject's clause narrowing, so a union subject's arm
# reads the member the `when` names (Ruby 4.0.5: "1" for 1, :a for :a).
class Labeler
  def label(value)
    case value
    when Symbol then value
    else value.to_s
    end
  end
end
