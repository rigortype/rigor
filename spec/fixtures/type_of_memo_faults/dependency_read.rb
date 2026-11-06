# frozen_string_literal: true

# ADR-129 G1': under a recording run, typing the `rand` call files a dependency read that it first found absent,
# so the entry stored for the call holds a read slice that no longer holds when the call is typed again from the
# same scope.
def pick
  x = rand < 0.5 ? "hello" : nil
  return if x.nil?

  x
end
