class C
  def other = (@y = true)
end

class E
  def set = (@x = "a")
end

class N
  def reset = (@n = nil)
end

class G
  def set = (@g = "a")
end

class W
  attr_writer :w
end

class S
  def self.set = (@s = "a")
end
