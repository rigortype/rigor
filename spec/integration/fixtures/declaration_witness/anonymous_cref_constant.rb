# frozen_string_literal: true

# A constant written in a class << self body belongs to the singleton class, and a def in a class opened below it
# resolves it there: Ruby's nesting inside `class ::E` is [E, #<Class:C>, C], so `E.new.m` returns :singleton_x.
# Rigor records the nesting ["E", "C"], through which no lookup reaches the singleton class's X (#1305's family,
# with #1520).

X = :top_x

class C
  class << self
    X = :singleton_x

    class ::E
      def m = X
    end
  end
end
