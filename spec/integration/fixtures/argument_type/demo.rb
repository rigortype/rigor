class Greeter
  def greet(name)
    "hello, #{name}"
  end

  def repeat(word, times)
    word * times
  end
end

g = Greeter.new

# OK calls — argument types accept the parameter types.
g.greet("world")
g.repeat("ho", 3)
