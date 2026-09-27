# frozen_string_literal: true

# The declaration-fact witness's positive control (#1507): every relation holds on it today, so the harness is
# shown to say "agree" before any issue fixture is read as a finding. It covers a superclass, an include, an
# extend, def self, a class << self body, protected and private defs, and a class nested in a module.

module Greeting
  def hello = "hi"
end

module Loud
  def shout = "HI"
end

class Base
  def base_method = 1
end

class Widget < Base
  include Greeting
  extend Loud

  def self.build = new

  class << self
    def registry = []
  end

  def render = "w"

  protected

  def weight = 1

  private

  def secret = 2
end

module Outer
  class Inner < Widget
    def render = "inner"
  end
end
