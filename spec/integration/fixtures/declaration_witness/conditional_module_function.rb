# frozen_string_literal: true

# ADR-119 WD3 — a bare `module_function` under a condition. Ruby applies the toggle to the body's later `def`s (a
# modifier `if` opens no scope), so `fmt2` is a module function: a private instance copy and a public singleton
# copy. The visibility walk keeps the default it had outside the `if` and records `Helpers2#fmt2` as public, which
# ADR-119 C1d-b contests (an uncertain toggle). The singleton copy is `possible`, through the self-extend edge the
# tables model a bare `module_function` with.

module Helpers2
  module_function if RUBY_VERSION >= "3"

  def fmt2(value) = value.to_s
end
