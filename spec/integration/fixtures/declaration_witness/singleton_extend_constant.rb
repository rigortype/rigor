# frozen_string_literal: true

# #1305: the singleton class's ancestors include what C extends, so a def in class << self finds M::Y. Rigor
# records the nesting ["C"], whose ancestry search is the instance side and never meets M.

Y = :top

module M
  Y = :m
end

class C
  extend M

  class << self
    def foo = Y
  end
end

raise unless C.foo == :m
