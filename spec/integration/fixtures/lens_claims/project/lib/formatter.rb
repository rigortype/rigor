class Formatter
  def format(value, mode:) = value
  def integer(value) = value
  def union(value) = value
  def generic(value) = value
  def response(value) = value
  def project(value) = value
  def unrelated(value) = value
  def dynamic(value) = value
  def unsupported(value) = value
  def optional(value = "", *rest, flag: false) = value
  def unmatched(value) = value
  def keyword(value:) = value
  def overloaded(value) = value
  def forwarding(...) = ""
  def inferred = ""
  # @extrbs () -> non-empty-string
  def extended = ""
  def refined(value) = value
  def refined_keyword(value:) = value
  def boolean(value) = value
  def pair(first, second) = second
  attr_reader :attribute
  define_method(:omitted) { "" }
end

module Utilities
  module_function
  def callable = ""
end

module Project
  class A; end
  class B < A; end
  class C; end
end

module App
  class Data < Hash; end
  class API
    def shadow = ""
  end
end

module Hidden
  class API
    def shadow = ""
  end
end

class Integer
  def documented = ""
end

def top_level = ""
