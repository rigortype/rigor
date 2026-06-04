require "rigor/testing"
include Rigor::Testing

# HashShape mid/low-priority handler folds (coverage uplift).

# one? — precise bool from the static pair count.
assert_type("true", { a: 1 }.one?)
assert_type("false", { a: 1, b: 2 }.one?)

# fetch_values — present keys lift to a Tuple of values.
assert_type("[1, 2]", { a: 1, b: 2 }.fetch_values(:a, :b))

# assoc — Tuple[key, value] for a known key, nil for a missing one.
assert_type("[:b, 2]", { a: 1, b: 2 }.assoc(:b))
assert_type("nil", { a: 1, b: 2 }.assoc(:z))

# key — reverse lookup over all-Constant values.
assert_type(":b", { a: 1, b: 2 }.key(2))
assert_type("nil", { a: 1, b: 2 }.key(99))

# rassoc — reverse of assoc: Tuple[key, value] for the first matching value.
assert_type("[:b, 2]", { a: 1, b: 2 }.rassoc(2))
assert_type("nil", { a: 1, b: 2 }.rassoc(99))

# has_value? / value? — decidable membership over Constant values.
assert_type("true", { a: 1, b: 2 }.has_value?(1))
assert_type("false", { a: 1, b: 2 }.value?(9))

# default — a literal HashShape carries no default value.
assert_type("nil", { a: 1 }.default)

# deconstruct_keys returns the receiver shape; the chained key?
# call then folds against it.
assert_type("true", { a: 1 }.deconstruct_keys(nil).key?(:a))

# Containment comparison between two closed HashShapes.
assert_type("true", { a: 1 } < { a: 1, b: 2 })
assert_type("false", { a: 1, b: 2 } < { a: 1, b: 2 })
assert_type("true", { a: 1, b: 2 } >= { a: 1 })
