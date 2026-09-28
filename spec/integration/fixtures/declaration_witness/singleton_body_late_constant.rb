# frozen_string_literal: true

# #1305: a def in a class << self body resolves constants in the singleton class first, including one the body
# writes after the def. Rigor records the nesting ["C"], which reaches the top-level X instead.

X = :top

class C
  class << self
    def foo = X
    X = :sing
  end
end

raise unless C.foo == :sing
