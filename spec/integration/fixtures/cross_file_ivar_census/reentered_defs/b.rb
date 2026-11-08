class CrossEvalDef
  def poke = self.class.class_eval { def set = (@x = "a") }
end

class CrossSingletonEvalDef
  def poke = singleton_class.class_eval { def set = (@x = "a") }
end

class CrossOtherEvalDef
  def poke = Other.class_eval { def set = (@x = "a") }
end

class CrossClassNewEvalDef
  def poke = Class.new.class_eval { def set = (@x = "a") }
end

class CrossEvalOtherSingleton
  def poke = Other.singleton_class.class_eval { def set = (@x = "a") }
end

class CrossEvalOtherNewClass
  def poke = Other.new.class.class_eval { def set = (@x = "a") }
end

class CrossEvalOtherNewSingleton
  def poke = Other.new.singleton_class.class_eval { def set = (@x = "a") }
end

class CrossEvalLiteralClass
  def poke = "s".class.class_eval { def set = (@x = "a") }
end

class CrossEvalLiteralSingleton
  def poke = [1].singleton_class.class_eval { def set = (@x = "a") }
end

class CrossEvalOtherClass
  def poke = Other.class.class_eval { def set = (@x = "a") }
end

class CrossEvalOtherDup
  def poke = Other.dup.class_eval { def set = (@x = "a") }
end

class CrossEvalOtherSuperclass
  def poke = Other.superclass.class_eval { def set = (@x = "a") }
end

class CrossDefineOtherSingleton
  def poke = Other.singleton_class.class_eval { define_method(:set) { @x = "a" } }
end

class CrossSingletonSideClassEval
  def self.poke = singleton_class.class_eval { def set = (@x = "a") }
end

class CrossSingletonBodyDef
  def poke
    class << self
      def set = (@x = "a")
    end
  end
end

class CrossSingletonOtherNewDef
  def poke
    class << Other.new
      def set = (@x = "a")
    end
  end
end

class CrossCallEvalDef
  def poke = klass.class_eval { def set = (@x = "a") }
end
