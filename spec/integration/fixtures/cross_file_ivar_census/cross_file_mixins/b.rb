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
