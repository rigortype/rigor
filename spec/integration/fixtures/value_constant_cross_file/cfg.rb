# Issue #1963 — constants another file reads in `when` tests (`use.rb`).
module Cfg
  NAME = "x"
  PATTERN = /a/
  CHECK = ->(x) { x == 1 }
  TEXT = String
  RANGE = (1..5)
end
