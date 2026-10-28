# Issue #2079 review S1 — a String another file or an ancestor writes may be mutated in place where the write cannot
# see it, so it joins as `String`, not its literal. Under Ruby 4.0.5, `k.start; k.c1 == 1` (`@s` is "abc" after the
# other file's `<<`), and `km.set; km.shout; km.c1 == 2` (`@t` is "ABC" after `upcase!`).
class K
  def initialize = (@s = nil)

  def c1
    return 0 unless @s

    if @s.length > 0 then 1 else 2 end
  end
end

module MutM
  def set = (@t = "abc")
end

class KM
  include MutM
  def initialize = (@t = nil)
  def shout = @t&.upcase!

  def c1
    return 0 unless @t

    if @t.start_with?("a") then 1 else 2 end
  end
end
