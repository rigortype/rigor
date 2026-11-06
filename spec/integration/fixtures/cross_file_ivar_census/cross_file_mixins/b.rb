class F
  include CrossM
  def initialize = (@cm = nil)
  def get = @cm.upcase
end

class CrossSub < CrossBase
  def initialize = (@cb = nil)
  def get = @cb.upcase
end

class ReopenedIncluder
  prepend Reopened
  def initialize = (@r = nil)
  def get = @r.upcase
end

# Issue #2487 — a module including a module declared in a later file: Ruby 4.0.5 returns "A" on any includer after
# `reset; set`.
module CrossOuter
  include CrossInner
  def reset = (@ci = nil)
  def get = @ci.upcase
end
