Plain = Struct.new(:a, :b)
WithBlock = Struct.new(:a, :b) do
  def t
    a
  end
end

p1 = Plain.new(1, 2)
w1 = WithBlock.new(1, 2)
p1.a
w1.a
w1.t
