# frozen_string_literal: true

# #1968 — a bare `public`, `private` or `protected` after a bare `module_function` ends the module_function mode, so
# a later def is an instance method only, with the visibility the toggle names. A named visibility call leaves the
# mode alone, a `private` before the toggle does not stop it, and a reopened body starts with the mode off.
# A reset under an `if` that does not run leaves the mode on, and one in a class-creating block changes that class only.

module ResetPublic
  module_function

  def a = 1

  public

  def b = 2
end

module ResetPrivate
  module_function

  def a = 1

  private

  def c = 3
end

module ResetProtected
  module_function

  protected

  def d = 1
end

module PrivateFirst
  private

  module_function

  def b = 1
end

module NamedVisibility
  module_function

  def a = 1

  public :a

  def b = 2
end

module ResetThenToggle
  module_function

  public

  def b = 2

  module_function

  def c = 3
end

module ResetPublic
  def e = 5
end

module ResetUnreached
  module_function

  if RUBY_VERSION < "1"
    public
  end

  def f = 6
end

module ResetInClassBlock
  module_function

  Hidden = Class.new(StandardError) do
    private

    def hidden = 0
  end

  def g = 7
end
