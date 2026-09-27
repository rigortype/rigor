# frozen_string_literal: true

# #1305: a private constant in the singleton class still resolves for a def in class << self, though
# `constants(false)` does not list it. Rigor records the nesting ["C"], which reaches the top-level X instead.

X = :top

class C
  class << self
    X = :sing
    private_constant :X

    def foo = X
  end
end

raise unless C.foo == :sing
