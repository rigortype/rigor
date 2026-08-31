class ErrSub < ::NoMethodError
  def self.build(key)
    message = "failed #{key}"
    new(message)
  end
end

class PlainSub
  def self.build(key)
    new
  end
end

EB = ErrSub.build(:a)
PB = PlainSub.build(:a)
