# frozen_string_literal: true

class BaseOnlySubclassed
  def hi = 1
end

module Mixin
  def mixed = 2
end
