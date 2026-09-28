# frozen_string_literal: true

# #1305: a def in class << self searches the singleton class's ancestors, which hold the superclass's singleton
# class but not the superclass, so it reaches the top-level X. Rigor records the nesting ["C"], whose ancestry
# search meets B's X instead.

X = :top

class B
  X = :b
end

class C < B
  class << self
    def foo = X
  end
end

raise unless C.foo == :top
