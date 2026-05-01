require "rigor/testing"
include Rigor::Testing

# `return if x.nil?` is an early-return guard: the rest of the
# method body only runs when `x` is non-nil, so the analyzer
# drops `nil` from the union after the guard line.
def go(_)
  x = if rand < 0.5
    "hello"
  else
    nil
  end
  return if x.nil?

  assert_type('"hello"', x)
  x
end
