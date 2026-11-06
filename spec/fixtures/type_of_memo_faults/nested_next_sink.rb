# frozen_string_literal: true

# ADR-129 G1': a Resource touch one capture below the outermost. Typing the `map` call's block evaluates the
# `next`, which writes the installed next sink. The `first` call around it is typed again as the receiver of
# `to_s`, and each typing evaluates the `next` again.
[1, 2].map do |x|
  y = x + 1
  next y if y > 1

  y
end.first.to_s
