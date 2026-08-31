class SAcc
  class << self
    attr_accessor :tk
  end
  self.tk = [1, 2, 3]
end

TK = SAcc.tk

class IAcc
  attr_accessor :v

  def initialize
    @v = 7
  end
end

IV = IAcc.new.v
