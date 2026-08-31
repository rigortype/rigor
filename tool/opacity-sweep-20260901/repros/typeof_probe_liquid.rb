# type-of minimal repros for liquid case analysis (same-file only)
class MyError < StandardError
end

class Iter
  include Enumerable

  def each
    yield 1
  end
end

def opt_hash(flag)
  h = flag ? { 'a' => 1 } : nil
  h.key?('a')
end

e = MyError.new
e.message
Iter.new.sort
Integer('10')
Warning.warn('x')
