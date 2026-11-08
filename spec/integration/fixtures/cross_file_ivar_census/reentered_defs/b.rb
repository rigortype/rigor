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
