# Issue #2170 — a module or superclass another file declares (or reopens) writes the includer's ivar. Under Ruby
# 4.0.5 each `get` returns "A" after `set`.
module CrossM
  def set = (@cm = "a")
end

class CrossBase
  def set = (@cb = "a")
end

module Reopened
end
