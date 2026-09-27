# frozen_string_literal: true

# #1305: a def in class << self searches the singleton class's ancestors, which leave out what C includes, so it
# reaches the top-level X. Rigor records the nesting ["C"], whose ancestry search meets M's X instead.

X = :top

module M
  X = :m
end

class C
  include M

  class << self
    def foo = X
  end
end

raise unless C.foo == :top
