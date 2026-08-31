# which parameter shapes break return inference
class Shapes
  def opt_int(_a = 1)
    42
  end

  def opt_true(_a = true)
    42
  end

  def kw_default(_a: 1)
    42
  end

  def kw_required(a:)
    42 + a - a
  end

  def splat(*_rest)
    42
  end

  def kwsplat(**_rest)
    42
  end

  def block_param(&_blk)
    42
  end
end

s = Shapes.new
s.opt_int
s.opt_true
s.kw_default
s.kw_required(a: 1)
s.splat
s.kwsplat
s.block_param
