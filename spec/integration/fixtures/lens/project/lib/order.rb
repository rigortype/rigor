class Order
  def amount = 42

  def note(text, *rest, key:, flag: false, **opts, &blk) = text

  def each_line
    yield "line"
  end

  def broken = amount.upcase
end
