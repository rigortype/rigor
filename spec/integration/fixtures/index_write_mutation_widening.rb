require "rigor/testing"
include Rigor::Testing

# `h[k] ||= v`, `h[k] &&= v` and `h[k] += v` store through `[]=`
# but Prism gives each its own node class, so none of them was a
# `[]=` CallNode and none reached MutationWidening. A collection
# written only that way kept the literal shape its seed gave it —
# `@rows.empty?` folded to `Constant[true]` on a hash the class
# fills — and the compound guard below drew a false
# `flow.always-truthy-condition`.

# Straight-line: the local keeps no empty-shape claim after the
# or-write, so `empty?` stays `bool` rather than folding to true.
local_or = {}
local_or[:a] ||= 1
local_or_empty = local_or.empty?

local_op = {}
local_op[:a] = 0
local_op[:a] += 1
local_op_empty = local_op.empty?

local_array = []
local_array[0] ||= :first
local_array_empty = local_array.empty?

# Cross-method: the class-ivar pre-pass observes the or-write in
# `add` and widens the `initialize` seed for every other method
# body, exactly as it already did for `@h[k] = v`.
class Rows
  def initialize
    @rows = {}
  end

  def add(key)
    @rows[key] ||= {}
  end

  def bump(key)
    @rows[key] &&= 2
  end

  # The plugin_facts.rb worked site: a compound guard whose left
  # operand is typed and whose right reads the mutated ivar.
  def row(owner)
    return nil if owner.nil? || @rows.empty?

    @rows[owner]
  end
end
