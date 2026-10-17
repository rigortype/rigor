# frozen_string_literal: true

# Issue #1984 — the singleton methods' visibilities: `private_class_method` / `public_class_method` in each argument
# form, `class << self` with a bare or wrapping `private` or a named `private :x`, an attr there, a `def self.x` under
# a bare `private`, a redefinition after `private_class_method`, and `singleton_class.class_eval`. Each class is one
# shape; Ruby's answer is what the witness records.

class NamedClassMethod
  def self.x = 1
  private_class_method :x
end

class WrappedClassMethod
  private_class_method def self.x = 1
end

class StringAndListClassMethod
  def self.s = 1
  def self.l = 1
  private_class_method "s"
  private_class_method [:l]
end

class PublicAgain
  private_class_method def self.x = 1
  public_class_method :x
end

class SelfDefUnderPrivate
  private

  def self.x = 1

  protected

  def self.y = 1
end

class SingletonBareToggle
  class << self
    def open = 1

    private

    def x = 1
    attr_reader :r
  end
end

class SingletonWrapping
  class << self
    private def x = 1
    private attr_writer :w
  end
end

class SingletonNamed
  class << self
    def x = 1
    private :x
  end
end

class SingletonPublicAgain
  class << self
    private

    def x = 1
    public :x
  end
end

class RedefinedAfter
  private_class_method def self.x = 1
  def self.x = 2
end

class SingletonClassEval
  singleton_class.class_eval do
    private

    def x = 1
  end
end

class PrivateNew
  private_class_method :new
  def self.build = new
end
