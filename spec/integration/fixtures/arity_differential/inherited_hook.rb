# An `inherited` hook on the superclass extends every subclass with `Pair1607h`, which sits ahead of
# `Base1607h.build` on the subclass's singleton, so `Sub1607h.build(1, 2)` runs the module's two-parameter method and is
# correct under Ruby. The singleton chain records no edge for a hook, so the candidate-set read declines (ADR-119 WD3,
# errata 2026-10-08); master read `Base1607h.build(kind)` and fired. The names are this file's own.
module Pair1607h
  def build(left, right) = [left, right]
end

class Base1607h
  def self.inherited(subclass)
    super
    subclass.extend(Pair1607h)
  end

  def self.build(kind) = kind
end

class Sub1607h < Base1607h
end

Sub1607h.build(1, 2)
