require "rigor/testing"
include Rigor::Testing

# `Class.new(Parent) { |c| ... }` returns the freshly-created
# anonymous subclass of Parent, statically typed as
# `singleton(Parent)`. The block parameter `c` carries the
# same type so calls like `c.<singleton-method>` resolve
# against the parent's singleton surface rather than dropping
# to bare `Class`.
#
# Pre-fix: `Class.new` typed as `Nominal[Class]` and the block
# parameter typed as `Nominal[Class]`, so a downstream
# `klass.<class-method>` (Rails' `klass.table_name = ...`,
# Sequel's `klass.dataset = ...`) reported `undefined-method`.

klass_with_parent = Class.new(StandardError) do |c|
  assert_type("singleton(StandardError)", c)
end
assert_type("singleton(StandardError)", klass_with_parent)

# No-parent form: the new class is a subclass of Object.
empty_klass = Class.new do |c|
  assert_type("singleton(Object)", c)
end
assert_type("singleton(Object)", empty_klass)
