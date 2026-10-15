# frozen_string_literal: true

# PR #1981's review — a `Class.new` / `Struct.new` / `Data.define` / `Module.new` block that no constant
# names is the anonymous class's body: its `attr_*` members, wrapped defs and toggles do not reach the enclosing
# class. Checked against Ruby on the visibilities relation only: the witness does not compare an anonymous class's
# members with Ruby's.

class LocalFactory
  attr_reader :c

  klass = Class.new do
    private

    attr_reader :c
  end
  klass.name
end

class IvarFactory
  attr_reader :d

  @k = Struct.new(:z) do
    private attr_reader :d
  end
end

class ArgumentFactory
  def self.register(klass) = klass

  def e = 1
  register(Class.new do
    private def e = 2
  end)
end

class BareFactories
  def f = 1
  def g = 1
  def h = 1

  Data.define(:z) do
    private def f = 2
  end
  Module.new do
    private

    def g = 2
  end
  Class.new do
    private

    def h = 2
  end
end
