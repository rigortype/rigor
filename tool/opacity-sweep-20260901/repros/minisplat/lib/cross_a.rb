class CrossErr < ::NoMethodError
  def self.build(key)
    message = "x #{key}"
    new(message)
  end
end

class CrossPlain
  def self.build(key)
    new
  end
end

class CrossPlain
  def imeth(a)
    42
  end

  def selfret(a)
    @z = a
    self
  end
end

SAMEF1 = CrossPlain.build(:a)
SAMEF2 = CrossPlain.new.imeth(1)

SAME_BAD = CrossPlain.build(:a).nosuch_same_xyz
