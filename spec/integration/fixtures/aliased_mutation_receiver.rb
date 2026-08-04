require "rigor/testing"
include Rigor::Testing

# Issue #277 — a mutation whose receiver is a *selection over variables* rather
# than a bare variable read.
#
# `(kind == :required ? required : optional)[key] = info` mutates whichever of
# the two hashes the ternary picked, but the receiver-widening walk only
# recognised a bare `LocalVariableReadNode` / `InstanceVariableReadNode`
# receiver, so BOTH hashes kept the empty `HashShape` seed the literal `{}`
# wrote. `collect`'s return then read as the fully value-pinned
# `{ required: {}, optional: {} }`, and the caller's
# `shape[:required].empty? && shape[:optional].empty?` folded to
# `Constant[true]` — a `flow.always-truthy-condition` on a condition that is
# false for every input carrying a row.
#
# Reduced from `Rigor::Plugin::DrySchema::SchemaScanner.collect_schema_shape`,
# where the FP fired on `each_block_type_info`'s emptiness check. Two features
# of that shape are load-bearing and are both preserved here:
#
#   1. the block is handed to a user-defined method that FORWARDS it, so the
#      engine cannot classify the call as `:non_escaping` and the ADR-56
#      captured-writeback path does not run — post-call widening is the only
#      thing standing between the seed and the caller;
#   2. `collect` is self-recursive through `element_info`, so its return type is
#      decided by the ADR-55 fixpoint. The fixpoint faithfully reproduces
#      whatever the body computes: with the seed left un-widened it converged on
#      the pinned empty shape and handed the caller a statically decided
#      condition. The recursion is what SURFACED the defect (without it the
#      cycle guard masked the body's result behind `Dynamic[top]`); the mutation
#      receiver is what CAUSED it.
#
# The union across the recursive edge must stay open: `required` / `optional`
# are `Hash`, never the empty `HashShape`.
module SchemaWalk
  module_function

  # `rows` is `[[kind, key, nested_rows_or_nil], ...]`.
  def collect(rows)
    required = {}
    optional = {}
    declared = { required: [], optional: [] }
    each_row(rows) do |kind, key, nested|
      declared[kind] << key
      info = element_info(nested)
      (kind == :required ? required : optional)[key] = info if info
    end
    { required: required.freeze, optional: optional.freeze, declared: declared }.freeze
  end

  def each_row(rows, &)
    forward(rows, &)
  end

  def forward(rows, &block)
    rows.each { |kind, key, nested| block.call(kind, key, nested) }
  end

  # The self-recursive edge: a nested row's element info is the collector's own
  # result, so `collect` is inferred through a cycle.
  def element_info(nested)
    return nil if nested.nil?

    shape = collect(nested)
    return nil if shape[:required].empty? && shape[:optional].empty?

    { nested: shape }
  end
end

shape = SchemaWalk.collect([[:required, :email, nil], [:optional, :tags, [[:required, :id, nil]]]])

# `required` / `optional` are `Hash`, not the empty `HashShape` seed — the union
# across the recursive edge stays open and `element_info`'s emptiness guard is
# not statically decided.
#
# `declared` is a KNOWN, deliberate residual and marks the boundary of the fix:
# `declared[kind] << key` mutates the array an INDEX READ returned, and an index
# read names an object no binding can be attributed to, so the widening declines
# rather than guessing which entry moved. It folds no condition here, so it is
# not a false-positive source; tightening it would need element-level tracking
# inside a `HashShape`, which is a separate feature.
assert_type("{ required: Hash, optional: Hash, declared: { required: [], optional: [] } }", shape)
