# A `def` inside control flow: a possible definer (ADR-119 WD3), so the arity read declines; tp-lost by design.
class CondDef
  if RUBY_VERSION > "3"
    def only(a) = a
  end
end

CondDef.new.only(1, 2)
