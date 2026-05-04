require "pathname"
require "rigor/testing"
include Rigor::Testing

# v0.0.6 — Pathname catalog import. Pathname is a thin
# wrapper that mostly delegates to File / Dir / FileTest,
# so the catalog's payoff is narrower than the Numeric or
# String imports: most methods classify `:dispatch` and
# their precision still flows through the RBS tier. What
# the import buys us is:
#
# 1. `Pathname.new(...)` resolves to `Nominal[Pathname]`
#    so downstream method dispatch knows the receiver class.
# 2. The blocklist defensively covers the conventional
#    `:initialize_copy` so a hypothetical future
#    `Constant<Pathname>` carrier cannot fold an aliasing
#    copy through the catalog.
# 3. The lone `:leaf` method (`<=>`) is now catalog-folded
#    rather than punted to RBS.

p1 = Pathname.new("/usr/bin/ruby")
assert_type("Pathname", p1)

# `Pathname#basename` returns a Pathname (via File.basename
# wrapped in Pathname.new); RBS knows the return type.
basename = p1.basename
assert_type("Pathname", basename)

# `Pathname#extname` returns the string extension.
extname = p1.extname
assert_type("String", extname)

# `Pathname#to_s` returns the underlying String.
str = p1.to_s
assert_type("String", str)

# `<=>` is catalog-classified `:leaf` and reaches the
# catalog tier; the RBS tier widens the return to
# `Integer | nil`, which Rigor describes as `Integer`
# under the `:short` verbosity.
cmp = p1 <=> Pathname.new("/usr/bin/ruby")
assert_type("Integer", cmp)
