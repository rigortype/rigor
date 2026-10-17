# frozen_string_literal: true

# The witness's positive control for the self-extend edge that models a bare module_function (#1507). `fmt` is a
# module function in Ruby; `early`, written before the call, is an instance method only, which the tables' orderless
# self-extend makes a `possible` singleton method. The instance copy of `fmt` is private in Ruby and in the
# visibility table (#1569).

module Helpers
  def early = 1

  module_function

  def fmt(value) = value.to_s
end
