require "rigor/testing"
include Rigor::Testing

# A multi-assign target `h[k]` stores through `[]=` on `h` exactly as
# `h[k] = v` does, but Prism gives it its own node class
# (`IndexTargetNode`) under the `MultiWriteNode`, and the destructuring
# binder skips every target that is not a variable. Nothing observed
# the store, so the receiver kept the literal shape its seed gave it
# and a later read folded against the stale value.

# Straight-line: `multi[:a] == 0` folded to `true` on a hash whose
# slot holds `1`.
multi = { a: 0 }
multi[:a], _multi_z = 1, 2
puts "zero" if multi[:a] == 0

# A target nested in a `(…)` group stores the same way.
nested = { a: 0 }
(nested[:a], _nested_q), _nested_r = [1, 2], 3
puts "zero" if nested[:a] == 0

# So does a splatted one: `*splat[0]` stores the `[2, 3]` rest.
splat = [[0]]
_splat_head, *splat[0] = 1, 2, 3
puts "one" if splat[0].size == 1

# The stored value joins as content evidence. Before the fix the
# literal had no `:b`, so `stored[:b]` read `nil` and `upcase` drew
# `undefined method for nil` on a slot that holds "s".
stored = { a: 0 }
stored[:b], _stored_w = "s", 2
stored[:b].upcase

# The must-fire control: the multi-assign stores into `other`, so
# `kept` is still the literal and its condition genuinely always holds.
kept = { a: 0 }
other = {}
other[:a], _other_w = 1, 2
puts "zero" if kept[:a] == 0 # GENUINE-TRUTHY

# Cross-method: the class-ivar pre-pass observes the store in `set`
# and widens the `initialize` seed for every other method body.
class Slots
  def initialize
    @slots = { a: 0 }
    @kept = { a: 0 }
    @other = {}
  end

  def set
    @slots[:a], _y = 1, 2
    @other[:a], _w = 1, 2
  end

  def probe
    puts "zero" if @slots[:a] == 0
  end

  # The cross-method control: nothing stores into `@kept`.
  def probe_kept
    puts "zero" if @kept[:a] == 0 # GENUINE-TRUTHY
  end
end
