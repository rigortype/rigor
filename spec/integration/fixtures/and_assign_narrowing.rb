require "rigor/testing"
include Rigor::Testing

# Issue #2214 — `x &&= v` runs `v` only when `x` is truthy, as `x && (x = v)` does, so `v` reads `x` narrowed to its
# truthy part, in statement and value position alike. And a failed `=~` on a String leaves the match globals nil on
# the `||` edge. Each comment gives what Ruby 4.0.5 answers. GENUINE-NIL and GENUINE-UNDEFINED mark a call Ruby
# raises on.

# `local_and(true)` returns 2, `local_and(false)` nil.
def local_and(raw)
  c = raw ? 1 : nil
  c &&= c + 1
  assert_type("2?", c)
end

def ivar_and(raw)
  @x = raw ? 1 : nil
  @x &&= @x + 1
  assert_type("2?", @x)
end

def global_and(raw)
  $and_g = raw ? 1 : nil
  $and_g &&= $and_g + 1
  assert_type("2?", $and_g)
end

class CvarHolder
  def cvar_and(raw)
    @@and_v = raw ? 1 : nil
    @@and_v &&= @@and_v + 1
    assert_type("2?", @@and_v)
  end
end

# The index and attribute targets read their slot as Ruby does already: `index_and(true)` returns 2.
def index_and(raw)
  h = { k: (raw ? 1 : nil) }
  h[:k] &&= h[:k] + 1
end

class Box
  attr_accessor :a
end

def attr_and(raw)
  o = Box.new
  o.a = raw ? 1 : nil
  o.a &&= o.a + 1
end

# Value position: `element(true)` returns [2], `argument(true)` [[2, 2], {}], `interpolated(true)` "2".
def take(*args, **kwargs) = [args, kwargs]

def element(raw)
  c = raw ? 1 : nil
  [c &&= c + 1]
end

def argument(raw)
  c = raw ? 1 : nil
  take(c &&= c + 1, c)
end

def interpolated(raw)
  c = raw ? 1 : nil
  "#{c &&= c + 1}"
end

# A write in the value runs where the value runs: `written(true)` returns [3].
def written(raw)
  c = raw ? 1 : nil
  [c &&= (d = c + 1; d + 1)]
end

# True positives kept. `or_assign(nil)` raises: `||=` runs its value when the variable is falsey. `sibling(false)`
# raises: an element after the `&&=` reads the variable as the statement form does after it.
def or_assign(raw)
  c = raw ? 1 : nil
  c ||= c + 1 # GENUINE-NIL
end

def sibling(raw)
  c = raw ? 1 : nil
  [(c &&= c + 1), c + 1] # GENUINE-NIL
end

# `failed_match("ab")` raises: the match failed, so `$1` is nil on the `||` edge, in either position.
def failed_match(x)
  s = "a#{x}"
  (s =~ /(\d)/) || $1.upcase # GENUINE-UNDEFINED
end

def failed_match_element(x)
  s = "a#{x}"
  [(s =~ /(\d)/) || $1.upcase] # GENUINE-UNDEFINED
end

# Controls: `matched("a1")` returns "1"; an untyped subject may be nil, whose `=~` leaves the previous match bound, so
# `untyped_subject(nil)` reads whatever `$1` held and is not reported.
def matched(x)
  s = "a#{x}"
  (s =~ /(\d)/) && $1.upcase
end

def untyped_subject(s)
  (s =~ /(\d)/) || $1
end
