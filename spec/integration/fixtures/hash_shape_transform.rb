require "rigor/testing"
include Rigor::Testing

# Per-pair block fold for `HashShape#transform_keys` and
# `HashShape#transform_values`. When the receiver is a closed
# HashShape the block is applied once per pair, preserving the
# HashShape structure rather than widening to `Hash[K, V]`.

# --- transform_keys ---

# `&:to_sym` on a string-keyed HashShape promotes each String
# key to the matching Symbol.
str_keyed = { "name" => "Alice", "age" => 30 }
sym_keyed = str_keyed.transform_keys(&:to_sym)
assert_type('{ name: "Alice", age: 30 }', sym_keyed)

# `&:to_s` on a symbol-keyed HashShape converts each Symbol key
# to its string form.
sym_hash = { name: "Alice", age: 30 }
str_hash = sym_hash.transform_keys(&:to_s)
assert_type('{ "name": "Alice", "age": 30 }', str_hash)

# `&:to_sym` on a symbol-keyed HashShape is a no-op on the keys.
sym_noop = sym_hash.transform_keys(&:to_sym)
assert_type('{ name: "Alice", age: 30 }', sym_noop)

# Full-block form: explicit block parameter instead of &:symbol.
block_keys = sym_hash.transform_keys { |k| k.to_s }
assert_type('{ "name": "Alice", "age": 30 }', block_keys)

# --- transform_values ---

# `&:to_s` converts every value to its string constant.
stringified = sym_hash.transform_values(&:to_s)
assert_type('{ name: "Alice", age: "30" }', stringified)

# Full-block form: explicit block parameter.
block_vals = sym_hash.transform_values { |v| v.to_s }
assert_type('{ name: "Alice", age: "30" }', block_vals)


# Heterogeneous value transform: each position is typed
# independently via per-pair dispatch.
hetero = { x: 1, y: "hello" }
up = hetero.transform_values { |v| v.to_s }
assert_type('{ x: "1", y: "hello" }', up)
