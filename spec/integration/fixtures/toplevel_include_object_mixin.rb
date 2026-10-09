require "rigor/testing"

# Issue #1697 — a top-level `include M` is `main.include`, which mixes M into
# `Object`, so M's instance methods answer a bare top-level call. The call is
# silent, and stays untyped until #1715.

module Greeting
  def greeting_count = 1
end

include Greeting

count = greeting_count
Rigor.assert_type("Dynamic[top]", count)
