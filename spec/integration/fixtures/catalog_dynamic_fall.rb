require "rigor/testing"
include Rigor::Testing

# Catalog / shape-fold gaps from the 2026-06-12 Dynamic-fall survey
# (buckets B5, B6, B9). Each was an IMPRECISE-SOUND `Dynamic[top]`
# fall before the precision-additive folds landed.

# --- B6: `flatten` element type recovery -----------------------------

# Tuple-of-tuples flattens to a single constant Tuple.
assert_type("[1, 2, 3, 4]", [[1, 2], [3, 4]].flatten)

# Deep nesting flattens fully with no depth argument.
assert_type("[1, 2, 3]", [1, [2, [3]]].flatten)

# A `Constant[Integer]` depth bounds the flatten.
assert_type("[1, 2, 3, 4]", [[1, 2], [3, 4]].flatten(1))

# (The `Array[Array[T]]` nominal-receiver path — `Array[Array[U]]
# #flatten -> Array[U]` — is covered by the ShapeDispatch unit spec,
# since constructing that nominal receiver from a literal here folds
# to a constant Tuple instead.)

# --- B5: `Array#to_h { block }` pair projection ----------------------

# The 2-Tuple block return projects into the Hash key/value params.
assert_type("Hash[Integer, Integer]", [1, 2, 3].to_h { |x| [x, x * 2] })

# String keys widen to their nominal too.
assert_type("Hash[String, Integer]", [1, 2].to_h { |x| [x.to_s, x] })

# --- B9: `Hash.new(default)` value-type lift -------------------------

# `Hash.new(0)` lifts the default into the value parameter.
assert_type("Hash[Dynamic[top], Integer]", Hash.new(0))

# A read of any key surfaces the default's type.
assert_type("Integer", Hash.new(0)[:missing])

# The counter idiom reads `Integer` after `+=`.
def counter
  h = Hash.new(0)
  h[:x] += 1
  h[:x]
end
assert_type("Integer", counter)

# `Hash.new` (no default) keeps the bare `Nominal[Hash]` answer — the
# default-arg fold declines on zero args, so this case is unchanged
# from pre-fold behaviour.
assert_type("Hash", Hash.new) # rubocop:disable Style/EmptyLiteral
