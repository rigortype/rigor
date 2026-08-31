# Controlled bisect for the AverageMedian D-candidate.
module M1 # plain: branches all puts
  def self.f(n, *_array)
    if n.instance_of? Integer
      puts 'a'
    else
      puts 'b'
    end
  end
end
M1.f(2, 3, 1)

module M2 # + bare raise in else
  def self.f(n, *_array)
    raise unless n.instance_of? Integer

    puts 'a'
  end
end
M2.f(2, 3, 1)

module M3 # + def-level rescue
  def self.f(n, *_array)
    raise unless n.instance_of? Integer

    puts 'a'
  rescue StandardError
    puts 'err'
  end
end
M3.f(2, 3, 1)

module M4 # no splat, def-level rescue
  def self.f(n)
    raise unless n.instance_of? Integer

    puts 'a'
  rescue StandardError
    puts 'err'
  end
end
M4.f(2)

module M5 # splat present, but called with no extra args
  def self.f(n, *array)
    puts "a"
  end
end
M5.f(2)

module M6 # instance-method splat, plain call
  class C
    def f(*array)
      puts "a"
    end
  end
end
M6::C.new.f(1, 2)
