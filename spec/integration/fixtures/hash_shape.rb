require "rigor/testing"
include Rigor::Testing

# Hash literals with Symbol keys lift to a `HashShape` carrier,
# so `[]` / `fetch` against a static key returns the per-entry
# value type. The shape itself describes as `{ name: "Alice",
# age: 30 }` — the same syntax the user wrote.
h = { name: "Alice", age: 30 }
assert_type('{ name: "Alice", age: 30 }', h)

n = h[:name]
a = h.fetch(:age)
assert_type('"Alice"', n)
assert_type("30", a)
