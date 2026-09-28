# frozen_string_literal: true

# #1305: singleton_extend_constant.rb with M's constant private. A def in class << self still finds it through the
# singleton class's ancestors. Rigor records the nesting ["C"], which reaches the top-level Y instead.

Y = :top

module M
  Y = :m
  private_constant :Y
end

class C
  extend M

  class << self
    def foo = Y
  end
end

raise unless C.foo == :m
