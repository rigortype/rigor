require "rigor/testing"
include Rigor::Testing

# A `for` index and a `rescue` reference may be an index target
# (`for h[k] in xs`, `rescue => h[k]`): Ruby stores the element / the
# exception through `[]=` on `h`, exactly as `h[k] = v` does. Prism
# gives the target its own node class (`IndexTargetNode`) outside any
# `MultiWriteNode`, and neither the `for` index binding nor the rescue
# reference binding observed the store, so the receiver kept the
# literal shape its seed gave it and a later read folded against the
# stale value.

# `for` with a single index target: `looped[:a]` is 2 after the loop.
looped = { a: 0 }
for looped[:a] in [1, 2]; end
puts "zero" if looped[:a] == 0

# `for` with an index target inside a multi-target index. It is the
# last slot because CRuby 4.0.5's Prism compiler raises on an index
# target in the first slot (`for pair[:a], w in ...` calls `[]=` on
# the Symbol); parse.y and the language agree with Rigor either way.
pair = { a: 0 }
for _pair_w, pair[:a] in [[2, 1]]; end
puts "zero" if pair[:a] == 0

# A bare splat index (`for *h[k] in`) stores the element as an array.
splat = { a: 0 }
for *splat[:a] in [[1, 2]]; end
puts "zero" if splat[:a] == 0

# `rescue => h[k]` stores the rescued exception.
rescued = { e: 0 }
begin
  raise "boom"
rescue => rescued[:e]
end
puts "zero" if rescued[:e] == 0

# The must-fire controls: each store lands in `other*`, so the `kept*`
# hashes are still their literals and the conditions genuinely hold.
kept_for = { a: 0 }
other_for = {}
for other_for[:a] in [1, 2]; end
puts "zero" if kept_for[:a] == 0 # GENUINE-TRUTHY

kept_pair = { a: 0 }
other_pair = {}
for _other_pair_w, other_pair[:a] in [[2, 1]]; end
puts "zero" if kept_pair[:a] == 0 # GENUINE-TRUTHY

kept_rescue = { e: 0 }
other_rescue = {}
begin
  raise "boom"
rescue => other_rescue[:e]
end
puts "zero" if kept_rescue[:e] == 0 # GENUINE-TRUTHY

# A `h[k] ||= default` narrowing on the stored slot is dropped, as a
# plain `h[k] = v` drops it: the read no longer answers the default.
narrowed_for = { e: nil }
narrowed_for[:e] ||= 0
for narrowed_for[:e] in [1, 2]; end
puts "zero" if narrowed_for[:e] == 0

narrowed_rescue = { e: nil }
narrowed_rescue[:e] ||= 0
begin
  raise "boom"
rescue => narrowed_rescue[:e]
end
puts "zero" if narrowed_rescue[:e] == 0

narrowed_multi = { e: nil }
narrowed_multi[:e] ||= 0
narrowed_multi[:e], _narrowed_z = 1, 2
puts "zero" if narrowed_multi[:e] == 0

# The control: a store into another slot keeps the narrowing.
narrowed_kept = { e: nil }
narrowed_kept[:e] ||= 0
for narrowed_kept[:f] in [1, 2]; end
puts "zero" if narrowed_kept[:e] == 0 # GENUINE-TRUTHY

# The same forms on an instance variable, in the method that seeds it
# and, through the class-ivar pre-pass, in a sibling method.
class IndexTargetSlots
  def initialize
    @looped = { a: 0 }
    @pair = { a: 0 }
    @rescued = { e: 0 }
    @kept = { a: 0 }
  end

  def fill
    for @looped[:a] in [1, 2]; end
    for _w, @pair[:a] in [[2, 1]]; end
    begin
      raise "boom"
    rescue => @rescued[:e]
    end
  end

  def fill_and_read
    @looped = { a: 0 }
    for @looped[:a] in [1, 2]; end
    puts "zero" if @looped[:a] == 0
    @pair = { a: 0 }
    for _w, @pair[:a] in [[2, 1]]; end
    puts "zero" if @pair[:a] == 0
  end

  def probe
    puts "zero" if @looped[:a] == 0
    puts "zero" if @pair[:a] == 0
    puts "zero" if @rescued[:e] == 0
  end

  # The cross-method control: nothing stores into `@kept`.
  def probe_kept
    puts "zero" if @kept[:a] == 0 # GENUINE-TRUTHY
  end
end
