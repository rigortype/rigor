class CrossOther
  def poke = Other.new.instance_eval { @x = "a" }
end

class CrossUnknown
  def poke(other) = other.instance_eval { @x = "a" }
end

class CrossEvalDefine
  def poke = self.class.class_eval { define_method(:set) { @x = "a" } }
end

class CrossOwnEvalDefine
  def poke = CrossOwnEvalDefine.class_eval { define_method(:set) { @x = "a" } }
end

class CrossSingletonDefine
  def poke = singleton_class.define_method(:set) { @x = "a" }
end

class CrossSingletonBodyDefine
  def poke
    class << self
      define_method(:set) { @x = "a" }
    end
  end
end

class CrossSelf
  def poke = instance_eval { @x = "a" }
end

class MayRun
  def set_c(flag) = (@c = "a" if flag)
  def set_l(items) = items.each { @l = "a" }
  def set_b = yield_self { @b = "a" }
end

class CrossSingleton
  def poke
    class << self
      @x = "a"
    end
  end
end

class CrossSingletonEvalDefine
  def poke = singleton_class.class_eval { define_method(:set) { @x = "a" } }
end

class CrossSendDefine
  def poke = self.class.class_eval { send(:define_method, :set) { @x = "a" } }
end
