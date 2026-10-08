# An `inherited` hook on the superclass defines `build` on every subclass's singleton, ahead of `Base1607h.build`, so
# `Sub1607h.build(1, 2)` runs the hook's two-parameter method and is correct under Ruby. The singleton chain records
# no edge for a hook, so the candidate-set read declines (ADR-119 WD3, errata 2026-10-08); master read
# `Base1607h.build(kind)` and fired on line 17. The names are this file's own.
class Base1607h
  def self.inherited(subclass)
    super
    subclass.singleton_class.send(:define_method, :build) { |left, right| [left, right] }
  end

  def self.build(kind) = kind
end

class Sub1607h < Base1607h
end

Sub1607h.build(1, 2)
