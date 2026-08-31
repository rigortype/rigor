# singleton-def discovery repros
class Foo
  class << self
    def val
      42
    end
  end

  def self.val2
    43
  end
end

Foo.val
Foo.val2
