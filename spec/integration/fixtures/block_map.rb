require "rigor/testing"
include Rigor::Testing

# `Array#map` with a literal block threads the per-element
# Constant through the block body. Folding `Integer#to_s` over
# the receiver union lifts each element to its stringified
# Constant — strictly more precise than the RBS-widened
# `Array[String]`.
strings = [1, 2, 3].map { |n| n.to_s }
assert_type('Array["1" | "2" | "3"]', strings)
