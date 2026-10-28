# Issue #2079 — another file's reopening of a class writes ivars this file's census holds. Under Ruby 4.0.5, after
# loading both files: `c.m == 1`, `c.m_yield { c.other } == 1`, `c.m_not == 2`, `c.m3 == 2`, and `E#get == "A"`
# after `set`.
class C
  def m
    @y = false
    other
    if @y then 1 else 2 end
  end

  def m_yield
    @y = false
    yield
    @y ? 1 : 2
  end

  def m_not
    @y = false
    other
    if !@y then 1 else 2 end
  end

  def m2
    @z = false
    local_other
    @z ? 1 : 2
  end

  def local_other = (@z = true)

  # Ruby 4.0.5 returns 2: `pure` is proven to write nothing, so `@q` is still `false`.
  def m3
    @q = false
    pure
    @q ? 1 : 2 # FIRES flow.always-truthy-condition
  end

  def pure = 1
  def typed_y = assert_type("bool?", @y)
end

class E
  def initialize = (@x = nil)
  def get = @x.upcase
end

# Ruby 4.0.5 raises NoMethodError: every write of `@n`, in either file, is `nil`.
class N
  def initialize = (@n = nil)
  def get = @n.upcase # FIRES call.undefined-method
end

# Only another file writes `@g`: this file's census holds no entry, so the read stays `Dynamic[top]`.
class G
  def get = assert_type("Dynamic[top]", @g)
end

# Ruby 4.0.5 returns "A" after `w.w = "a"`: the other file's `attr_writer` widens the entry with `Dynamic[top]`.
class W
  def initialize = (@w = nil)
  def get = @w.upcase
  def typed = assert_type("Dynamic[top]?", @w)
end

# Ruby 4.0.5 raises NoMethodError on `S.new.get`: the other file's `def self.set` writes the class object's `@s`.
class S
  def initialize = (@s = nil)
  def get = @s.upcase # FIRES call.undefined-method
end

# The file's own non-literal write keeps the type the census gives it: this file's coarse entries are not joined back.
class T
  def initialize = (@t = "a".upcase)
  def typed = assert_type("\"A\"", @t)
end

# Review m5 — another file's operator write joins as `Dynamic[top]`, not its operand's literal.
class Counter
  def initialize = (@n = 0)
  def typed = assert_type("0 | Dynamic[top]", @n)
end

# Review m5 — every distinct literal another file writes to one ivar joins, not only the first.
class Many
  def initialize = (@v = nil)
  def typed = assert_type("1 | 2 | nil", @v)
end
