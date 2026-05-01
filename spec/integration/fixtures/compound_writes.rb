require "rigor/testing"
include Rigor::Testing

# Compound assignments constant-fold and rebind. Each `+=` / `-=`
# is a binary call on the current Constant carrier, so the chain
# threads the precise integer all the way through.
n = 10
n += 5
n -= 3
assert_type("12", n)

# `||=` on a nil-bound local replaces it with the rvalue's type
# (here `Constant["hit"]`); the engine knows the lvalue is nil so
# the rvalue side definitely runs.
cached = nil
cached ||= "hit"
assert_type('"hit"', cached)
