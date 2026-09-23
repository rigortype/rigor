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

# `for` with an index target inside a multi-target index.
pair = { a: 0 }
for pair[:a], _pair_w in [[1, 2]]; end
puts "zero" if pair[:a] == 0

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
for other_pair[:a], _other_pair_w in [[1, 2]]; end
puts "zero" if kept_pair[:a] == 0 # GENUINE-TRUTHY

kept_rescue = { e: 0 }
other_rescue = {}
begin
  raise "boom"
rescue => other_rescue[:e]
end
puts "zero" if kept_rescue[:e] == 0 # GENUINE-TRUTHY

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
    for @pair[:a], _w in [[1, 2]]; end
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
    for @pair[:a], _w in [[1, 2]]; end
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
