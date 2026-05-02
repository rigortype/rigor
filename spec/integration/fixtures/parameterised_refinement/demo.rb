require "rigor/testing"
include Rigor::Testing

# Parameterised refinement payloads (v0.0.4 task C). The
# `rigor:v1:return:` directive accepts the full grammar in
# `Builtins::ImportedRefinements::Parser`:
#
#   rigor:v1:return: non-empty-array[Integer]
#   rigor:v1:return: non-empty-hash[Symbol, Integer]
#   rigor:v1:return: int<5, 10>
#
# At call sites, Rigor sees the parameterised carrier rather
# than the raw RBS-declared collection / Integer return.
class Catalog
  def positive_ids
    [1, 2, 3]
  end

  def attributes
    { name: 1 }
  end

  def small_index
    7
  end
end

c = Catalog.new

ids = c.positive_ids
assert_type("non-empty-array[Integer]", ids)
# RBS erasure folds the carrier back to its base nominal so
# Array-tier projections still apply.
assert_type("positive-int", ids.size)

attrs = c.attributes
assert_type("non-empty-hash[Symbol, Integer]", attrs)
assert_type("positive-int", attrs.size)

idx = c.small_index
assert_type("int<5, 10>", idx)
