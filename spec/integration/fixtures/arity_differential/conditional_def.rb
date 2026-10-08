# A `def` inside control flow: a possible definer (ADR-119 WD3), so its slot is contested and the arity read
# declines (C1d-a). Ruby 4.0 takes the branch, so the call raises and the silencing is `tp-lost` by design.
class CondDef
  if RUBY_VERSION > "3"
    def only(a) = a
  end
end

CondDef.new.only(1, 2)
