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
