require "rigor/testing"
include Rigor::Testing

# Set constant carrier — SetFolding (Tier D) folds constructor calls on
# Singleton["Set"] receivers when all arguments are statically known.
# The result is Constant[Set] rather than Nominal[Set].
# Ruby 4.0 Set#inspect format: Set[:a, :b] (no #<Set: ...> wrapper).

# Set[] variadic constructor
_set_empty_bracket = Set[]
assert_type("Set[]", _set_empty_bracket)

_set_symbols = Set[:a, :b, :c]
assert_type("Set[:a, :b, :c]", _set_symbols)

# Set.new with no arguments
_set_empty_new = Set.new
assert_type("Set[]", _set_empty_new)

# Set.new with a literal array — inferred as Tuple -> folded to Constant[Set]
_arr = %i[x y]
_set_from_tuple = Set.new(_arr)
assert_type("Set[:x, :y]", _set_from_tuple)

# Instance methods on a Constant[Set] receiver fold through ConstantFolding
_s = Set[:a, :b, :c]
assert_type("3", _s.size)
assert_type("false", _s.empty?)
assert_type("true", _s.include?(:a))
assert_type("false", _s.include?(:z))

# to_a / entries return a Tuple of the set's constant elements
_to_a = _s.to_a
assert_type("[:a, :b, :c]", _to_a)
_entries = _s.entries
assert_type("[:a, :b, :c]", _entries)

# Non-constant element prevents fold -> Nominal[Set] -> size gives non-negative-int
arr_dyn = [1, rand.to_i]
s_dynamic = Set.new(arr_dyn)
assert_type("non-negative-int", s_dynamic.size)

# Alias resolution — `length`, `member?`, and `+` are C-level aliases
# that the YAML catalog stores in the `aliases:` section rather than
# `instance_methods:`. The catalog now resolves them to the canonical
# entry so they fold identically.
_s2 = Set[:a, :b, :c]
assert_type("3", _s2.length)
assert_type("true", _s2.member?(:a))
assert_type("false", _s2.member?(:z))
_union = _s2 + Set[:d]
assert_type("Set[:a, :b, :c, :d]", _union)

# Binary set operations fold to a precise `Constant[Set]`. `&` /
# `intersection` join their leaf-pure siblings `|` / `-` / `^` despite
# the catalog flagging `set_i_intersection`'s C body block-dependent.
assert_type("Set[:b, :c]", _s2 & Set[:b, :c, :z])
assert_type("Set[:b, :c]", _s2.intersection(Set[:b, :c, :z]))
assert_type("Set[:a]", _s2 - Set[:b, :c])
assert_type("Set[:a, :z]", _s2 ^ Set[:b, :c, :z])
