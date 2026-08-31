class Saf
  def name
    "n"
  end
end

def g(flag)
  s = flag ? Saf.new : nil
  a = s&.name
  b = s.name
  [a, b]
end
