# A `def` inside control flow: the arity rule reads it as a definition.
class CondDef
  if RUBY_VERSION > "3"
    def only(a) = a
  end
end

CondDef.new.only(1, 2)
