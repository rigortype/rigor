# frozen_string_literal: true

# #1305: the singleton class's ancestors include the superclass's singleton class, so a def in C's class << self
# finds the Z that B's class << self wrote. Rigor records the nesting ["C"], which reaches the top-level Z.

Z = :top

class B
  class << self
    Z = :bsing
  end
end

class C < B
  class << self
    def foo = Z
  end
end

raise unless C.foo == :bsing
