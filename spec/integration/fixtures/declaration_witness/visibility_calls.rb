# frozen_string_literal: true

# Issues #1911, #1819, #1633 — a `def` or `attr_*` wrapped in a visibility call, and the visibility calls written on
# `self`, sent, splatted or given a block. Each class is one shape; Ruby's answer is what the witness records.

class WrappedDef
  private def kp; end
  private def secret = 1
  def after = 1
end

class PublicUnderPrivate
  private

  public def foo = 1
  def bar = 1
end

class WrappedAttrs
  protected attr_reader :r

  attr_reader :plain
  private attr_accessor :both

  private

  attr_writer :w

  public

  attr_accessor :name
  private :name
end

class ListedNames
  def a = 1
  def b = 1
  private %i[a]
  private [:b]
end

class BlockToggle
  private {}
  def a = 1
end

class SelfToggle
  self.private
  def a = 1
end

class SentToggle
  send(:private)
  def a = 1
end

class UnderscoreSentToggle
  __send__(:private)
  def a = 1
end

class SentWrapped
  send(:private, def a = 1)
  self.private def b = 1
  def c = 1
end

class EmptySplatToggle
  private(*[])
  def a = 1
end

class SplatNames
  def zz = 1
  private(*[:zz])
  def a = 1
end

class SingletonWrapped
  def x = 1
  private def self.x = 1
end

class ClassMethodWrapped
  private

  private_class_method def self.s = 1
  public_class_method def self.t = 1
  def a = 1
end

class ConditionalWrapped
  private def x = 1 if RUBY_VERSION > "3"
  def y = 1
end

module Memoizing
  def memoize(name) = name
end

class NestedWrapped
  extend Memoizing

  private memoize def x = 1
  def y = 1
end

class UncertainToggle
  private

  public if RUBY_VERSION > "3"
  attr_reader :ut
end

class ConditionalBlockToggle
  if true
    private {}
  end
  def a = 1
end
