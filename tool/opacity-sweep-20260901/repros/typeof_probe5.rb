# optional-parameter dispatch repros
class Opt
  def no_opt(name)
    "x-#{name}"
  end

  def with_opt(name, _vars = {})
    "x-#{name}"
  end

  def with_opt_used(name, vars = {})
    "x-#{name}-#{vars.size}"
  end

  def const_with_opt(_vars = {})
    42
  end
end

o = Opt.new
o.no_opt('a')
o.with_opt('a')
o.with_opt('a', {})
o.with_opt_used('a')
o.const_with_opt
o.const_with_opt({})
