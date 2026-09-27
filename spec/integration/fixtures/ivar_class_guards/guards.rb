require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1446 — a class guard on an instance variable typed `IO` narrows the arm as it narrows a local's. `@io` holds an
# `IO` here, and a test builds the same object around a `StringIO`, which is not an `IO` subclass, so the guarded call
# must not report. Ruby 4.0.5 answers nil under `STDOUT`, the captured text under a `StringIO`.
class Holder
  def initialize
    @io = STDOUT
  end

  def guarded_is_a = (@io.is_a?(StringIO) ? @io.string : nil) # QUIET-1446
  def guarded_kind_of = (@io.kind_of?(StringIO) ? @io.string : nil) # QUIET-1446
  def guarded_instance_of = (@io.instance_of?(StringIO) ? @io.string : nil) # QUIET-1446
  def guarded_case_equality = (StringIO === @io ? @io.string : nil) # QUIET-1446
  def guarded_case_when = (case @io when StringIO then @io.string end) # QUIET-1446

  def guarded_case_in
    case @io
    in StringIO then @io.string # QUIET-1446
    else nil
    end
  end

  # `StringIO` is disjoint from `IO`, so the arm reads `bot`, as it does for a local, and the falsey edge keeps `IO`.
  def is_a_type = (assert_type("bot", @io) if @io.is_a?(StringIO))
  def case_equality_type = (assert_type("bot", @io) if StringIO === @io)
  def falsey_type = (assert_type("IO", @io) unless @io.is_a?(StringIO))

  # A core method on a core receiver, and a core iterator whose block runs only core code, cannot reach `self`, so
  # the narrowing holds across them.
  def kept_across_core_calls
    return unless @io.is_a?(StringIO)

    total = [1, 2].sum
    [1, 2].each { |i| i.to_s }
    @io.string + total.to_s # QUIET-1446
  end

  # Control: an unguarded class-specific call on an `IO`-typed instance variable still reports (Ruby: NoMethodError).
  def unguarded = @io.string # FIRES-1446 call.undefined-method
end
