Point = Data.define(:x, :y) do
  def norm = (x * x) + (y * y)
end

Pair = Struct.new(:left, :right)
