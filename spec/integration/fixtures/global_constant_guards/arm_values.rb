require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1429 (the maintainer's amendment) — a guard the ordinary reading proves dead makes its arm gradual: the
# receiver reads `Dynamic[C]`, and the arm's value and the bindings it changes leave it as `Dynamic[T]`. What only the
# guard introduced therefore crosses a typed boundary by gradual consistency and is never diagnostic fuel. The
# signatures in `sig/arm_values.rbs` are the correct ones, and Ruby 4.0.5 runs every method below without error.

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

  # The arm's value is gradual; the variable it narrowed joins back with a gradual member.
  def arm_value_types(value)
    assert_type('"no" | Dynamic[:yes]', value.is_a?(Symbol) ? :yes : "no")
    value.to_s if value.is_a?(Symbol)
    assert_type("Dynamic[Symbol] | String", value)
  end

  # Only the arm the guard made live is gradual; the falsey arm keeps its value (Ruby 4.0.5: nil).
  def arm_binding(value)
    label = value.is_a?(Symbol) ? :sym : nil
    assert_type("Dynamic[:sym]?", label)
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
