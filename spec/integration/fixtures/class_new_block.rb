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

# No-parent form (#319): the block body is the new class's own
# body, so the class is NOT `Object` — it owns whatever the
# body defines, and `.new` takes the arity its `initialize`
# declares. Rendered without its call-site key so the assertion
# does not pin a line number.
empty_klass = Class.new do
  def answer
    42
  end
end
assert_type("singleton(#<Class>)", empty_klass)
assert_type("Integer", empty_klass.new.answer)

# The block PARAMETER form still carries the parent's singleton
# (`Nominal[Class]` otherwise), unchanged by #319.
parented = Class.new(StandardError) do |c|
  assert_type("singleton(StandardError)", c)
end
assert_type("singleton(StandardError)", parented)
