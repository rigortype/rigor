class Mini
  def self.plain(a)
    b = new
    b.append(a)
    b
  end

  def self.splat(*args)
    b = new
    args.each { |x| b.append(x) }
    b
  end

  def self.splat_send(*args)
    b = new
    args.each { |x| b.send("append", x) }
    b
  end

  def append(x)
    x
  end
end

P = Mini.plain(1)
S = Mini.splat(1, 2)
D = Mini.splat_send(1, 2)

class Mini2
  def self.splat_noblock(*args)
    b = Mini.new
    b
  end

  def self.plain_block(a)
    b = Mini.new
    [1, 2].each { |x| b.append(x) }
    b
  end

  def self.kwsplat(**opts)
    b = Mini.new
    b
  end
end

N1 = Mini2.splat_noblock(1, 2)
N2 = Mini2.plain_block(1)
N3 = Mini2.kwsplat(a: 1)

class Mini3
  def isplat(*args)
    42
  end

  def iplain(a)
    42
  end
end

I1 = Mini3.new.isplat(1)
I2 = Mini3.new.iplain(1)

RP = RUBY_PLATFORM == "java"
RQ = "abc" == "java"

class Mini4
  def rself(a)
    @x = a
    self
  end

  def dyn
    @x
  end
end

RS1 = Mini4.new.rself(1)
RS2 = Mini4.new.rself(Mini4.new.dyn)

class Mini5
  def dcall(a)
    @x << a
    self
  end
end

class Mini5Sub < Mini5
end

DC1 = Mini5.new.dcall(1)

class Mini6
  def plain6(a)
    @y = a
    self
  end
end

class Mini6Sub < Mini6
end

SB1 = Mini6.new.plain6(1)

module CondTools
  if 'string'.respond_to?(:upcase)
    def conddef(a)
      42
    end
  end

  def plaindef(a)
    42
  end
end

class UsesTools
  extend CondTools

  def self.drive
    x = conddef(1)
    y = plaindef(1)
    [x, y]
  end
end

class UsesTools2
  extend CondTools

  def self.own(a)
    42
  end

  def self.drive2
    z = own(1)
    w = UsesTools2.plaindef(1)
    [z, w]
  end
end

class UnionRecv
  def drive(flag)
    h = flag ? { a: 1 } : {}
    v = h[:a]
    s = flag ? "x" : "yy"
    l = s.length
    [v, l]
  end
end
