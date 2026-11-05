# frozen_string_literal: true

# ADR-129 G1': the threaded-flag shape from ADR-129's Context. The `tap` block takes no parameters, so its body
# enters with the enclosing scope object. Its first statement is typed twice from that one object: once inside
# the `tap` call's threaded fold, which suppresses threading for the nested `map` block, and once by the
# statement pass, which threads it. The nested block rebinds the captured `x`, so the two typings differ.
def threaded(arr)
  arr.each do |x|
    tap do
      r = [1].map do |c|
        x = c
        x + 1
      end
      r.first
    end
  end
end
