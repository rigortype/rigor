require "rigor/testing"
include Rigor::Testing

# v0.0.6 — Random catalog import. Random is the textbook
# example of "stateful by design": every call to `#rand` /
# `#bytes` advances the receiver's Mersenne-Twister state, so
# the catalog tier deliberately declines to fold any of those
# calls. Singleton `Random.rand` / `Random.bytes` mutate the
# default generator (`Random::DEFAULT`); `Random.new_seed` /
# `Random.urandom` are non-deterministic. What the import
# buys us:
#
# 1. `Random.new(...)` resolves to `Nominal[Random]` so
#    downstream method dispatch knows the receiver class.
# 2. The blocklist defends `:rand`, `:bytes`, `:new_seed`,
#    `:urandom`, and `:initialize_copy` so a hypothetical
#    future `Constant<Random>` carrier cannot fold a state-
#    advancing or non-deterministic call through the catalog.
# 3. The RBS tier still resolves return types, so user code
#    keeps `Integer` / `Float` / `String` precision on the
#    method results.

prng = Random.new(42)
assert_type("Random", prng)

# `Random#rand(Integer)` is catalog-blocklisted (advances MT
# state); the RBS tier resolves the Integer overload so the
# return widens to `Integer`.
assert_type("Integer", prng.rand(10))

# Same shape on the singleton path — `Random.rand(Integer)`
# is blocklisted but the RBS tier carries the Integer overload.
assert_type("Integer", Random.rand(10))

# `Random#bytes` returns a String per RBS; catalog-blocklisted
# because each call advances MT state.
assert_type("String", prng.bytes(8))
