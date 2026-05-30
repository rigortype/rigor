# frozen_string_literal: true

# ADR-36 nested-class emission — Mangrove's `Enum` DSL.
#
# `variants do variant <Const>, <Type> end` mints a nested subclass
# per variant; rigor-mangrove synthesises each one statically so the
# variant constant resolves, `.new` dispatches, and the `#inner`
# reader resolves to the declared payload type — no need to run
# Mangrove's runtime `const_missing` / `class_eval`.
#
# `Mangrove::Enum` is the extend-marker the substrate keys on; the
# real gem supplies it. The demo stubs it so the file stands alone.
module Mangrove
  module Enum; end
end

class Shape
  extend Mangrove::Enum

  variants do
    variant Circle, Float
    variant Label, String
  end
end

def demo
  # `Shape::Circle` resolves as a class; `.new` yields an instance;
  # `#inner` resolves to Float, so `.floor` (a Float method) is clean.
  radius = Shape::Circle.new(1.5)
  puts radius.inner.floor

  # `Shape::Label#inner` resolves to String.
  label = Shape::Label.new("hi")
  puts label.inner.upcase
end
