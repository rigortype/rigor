# A `def` in a meta-new constant write's block, which Ruby runs once as the class body: a certain definer (ADR-119
# WD3), so the read must keep firing.
MetaMade = Class.new do
  def one(a) = a
end

MetaMade.new.one(1, 2)
