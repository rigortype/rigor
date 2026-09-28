# frozen_string_literal: true

# #1305's family: the class << self body writes X after `class ::E` is opened, and E#m still finds it, because the
# method runs after the body has finished. Rigor records the nesting ["E", "C"], which cannot reach it.

X = :top_x

class C
  class << self
    class ::E
      def m = X
    end

    X = :singleton_x
  end
end

raise unless E.new.m == :singleton_x
