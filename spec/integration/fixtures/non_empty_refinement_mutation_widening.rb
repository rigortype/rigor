require "rigor/testing"
include Rigor::Testing

# An in-place mutator MUST invalidate the `non-empty-array` refinement that `empty?` / `any?`
# narrowing writes (ADR-47 §4-4), exactly as it already invalidates a `Tuple`.
#
# Without the `Type::Difference` arm in `MutationWidening#widen_for_mutator`, the refinement
# survives the mutator call: `ShapeDispatch` then projects `arr.size` off the stale carrier to
# `positive-int`, `ConstantFolding`'s range comparison folds `arr.size == 0` to `Constant[false]`,
# and `flow.always-falsey-condition` fires on code whose condition is TRUE at runtime.
#
# The `empty?` spelling of the check is shielded by the rule's defensive-predicate skip list; the
# `size == 0` comparison below is the unshielded channel, so it is what these sites exercise.

# Local receiver — the reported reproducer.
def probe_local
  arr = gets.to_s.chars
  return if arr.empty?

  arr.clear
  puts "emptied" if arr.size == 0

  arr
end

# Ivar receiver — ivars narrow through the same accessor pair.
class Buffer
  def initialize
    @items = gets.to_s.chars
  end

  def drain
    return if @items.empty?

    @items.clear
    puts "drained" if @items.size == 0

    @items
  end
end

# Block-body mutation of a captured local — routed through `widen_after_block`.
def probe_block
  arr = gets.to_s.chars
  return if arr.empty?

  [1, 2].each { arr.pop }
  puts "emptied" if arr.size == 0

  arr
end

# `any?`'s truthy edge writes the same refinement; `shift` invalidates it.
def probe_any_edge
  arr = gets.to_s.chars
  if arr.any?
    arr.shift
    puts "emptied" if arr.size == 0
  end

  arr
end
